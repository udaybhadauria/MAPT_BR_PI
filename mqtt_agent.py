import paho.mqtt.client as mqtt
import json, time, os, subprocess, threading

BROKER = "fd72:3456:789a::1"
PORT = 1883

TOPIC_CONFIG   = "rpi_jool/config"
TOPIC_STATUS   = "rpi_jool/status"
TOPIC_OUTPUT   = "rpi_jool/output"
TOPIC_SERVICES = "rpi_jool/services_status"

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))

client = mqtt.Client()
_connect_time = 0   # set when CONNACK is received

# -----------------------------
def _path(name):
    return os.path.join(SCRIPTS_DIR, name)

def run_script(name):
    print(f"[{name}] running...")
    result = subprocess.run(["bash", _path(name)], capture_output=True, text=True)
    if result.returncode == 0:
        print(f"[{name}] OK")
    else:
        print(f"[{name}] FAILED (rc={result.returncode})")
        if result.stdout.strip():
            print(f"[{name}] stdout: {result.stdout.strip()}")
        if result.stderr.strip():
            print(f"[{name}] stderr: {result.stderr.strip()}")
    return result.returncode

# -----------------------------
def publish_services():
    """Run check_services.sh then publish the result."""
    run_script("check_services.sh")
    services = json.load(open(_path("services_status.json")))
    client.publish(TOPIC_SERVICES, json.dumps(services), retain=True)

# -----------------------------
def publish_output():
    output = json.load(open(_path("output.json")))
    client.publish(TOPIC_OUTPUT, json.dumps(output), retain=True)

# -----------------------------
def publish_status(state):
    payload = {
        "state": state,
        "timestamp": int(time.time())
    }
    client.publish(TOPIC_STATUS, json.dumps(payload), retain=True)

# -----------------------------
def health_loop():
    """Broadcast service health every 5 seconds."""
    while True:
        try:
            publish_services()
        except Exception as e:
            print("health_loop error:", e)
        time.sleep(5)

# -----------------------------
def on_connect(client, userdata, flags, rc):
    global _connect_time
    _connect_time = int(time.time())
    print("Agent connected, rc=", rc)
    client.subscribe(TOPIC_CONFIG)

# -----------------------------
def on_message(client, userdata, msg):
    # Skip retained messages that were published before this session started
    try:
        meta = json.loads(msg.payload.decode()).get("_meta", {})
        if meta.get("revision", 0) < _connect_time:
            print("Skipping stale retained config (revision before connect)")
            return
    except Exception:
        pass

    print("CONFIG RECEIVED")
    publish_status("applying")

    try:
        # Save received config — strip _meta (protocol field, not config)
        config = json.loads(msg.payload.decode())
        config.pop("_meta", None)
        with open(_path("config_ui.json"), "w") as f:
            json.dump(config, f, indent=2)

        # Run config generation pipeline in order
        pipeline = [
            "generate_mac_ipv6.sh",
            "generate_config.sh",
            "generate_routes.sh",
            "return_policy.sh",
            "jool_apply.sh",
        ]
        for script in pipeline:
            rc = run_script(script)
            if rc != 0:
                publish_status(f"error:{script}")
                return

        publish_output()
        publish_services()
        publish_status("done")

    except Exception as e:
        print("on_message error:", e)
        publish_status("error")

# -----------------------------
client.on_connect = on_connect
client.on_message = on_message

# Start health broadcast thread (every 5 s)
threading.Thread(target=health_loop, daemon=True).start()

client.connect(BROKER, PORT)
client.loop_forever()
