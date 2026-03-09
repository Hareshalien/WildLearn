import os
import re
import io
import wave
import base64
import uuid
import threading
import time
import traceback

from flask import Flask, request, jsonify, Response
from google import genai
from google.genai import types

app = Flask(__name__)

# ── Google GenAI SDK client ───────────────────────────────────────────────────
GEMINI_API_KEY = "Place_key_here"
client = genai.Client(api_key=GEMINI_API_KEY)

# ── Model names ───────────────────────────────────────────────────────────────
MODEL_TEXT  = "gemini-2.5-flash"
MODEL_IMAGE = "gemini-2.5-flash-image"       
MODEL_TTS   = "gemini-2.5-flash-preview-tts"
MODEL_VEO   = "veo-3.1-generate-preview"
# ─────────────────────────────────────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────────────────────────────────────

def _extract_field(label: str, text: str, default: str = "Unknown") -> str:
    """Parse KEY: value lines robustly, ignoring markdown noise."""
    for line in text.splitlines():
        clean = re.sub(r'^[\s*#\-]+', '', line).strip().strip('*').strip()
        m = re.match(
            r'^\*{0,2}' + re.escape(label.upper()) + r'\*{0,2}\s*:\s*(.+)',
            clean, re.IGNORECASE,
        )
        if m:
            value = m.group(1).strip().strip('*').strip()
            if value:
                return value
    return default
def _make_wav(pcm_bytes: bytes) -> bytes:
    """Wrap raw 24 kHz mono 16-bit PCM in a WAV container."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(24000)
        wf.writeframes(pcm_bytes)
    return buf.getvalue()
# ─────────────────────────────────────────────────────────────────────────────
#  Health
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/", methods=["GET"])
def health():
    return jsonify({"status": "ok", "service": "BioMap AI Backend", "sdk": "google-genai"})
@app.route("/test", methods=["GET"])
def test():
    try:
        resp = client.models.generate_content(
            model=MODEL_TEXT,
            contents="Say: BioMap AI is working!",
        )
        return jsonify({"status": "ok", "response": resp.text})
    except Exception as e:
        return jsonify({"status": "error", "error": str(e)}), 500
# ─────────────────────────────────────────────────────────────────────────────
#  Generate Story
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/generate-story", methods=["POST"])
def generate_story():
    try:
        data           = request.get_json(force=True)
        base64_image   = data.get("base64Image", "")
        latitude       = data.get("latitude", 0)
        longitude      = data.get("longitude", 0)
        contributor_id = data.get("contributorId", "a contributor")
        local_area     = data.get("localArea", "an unspecified area")
        species        = data.get("species", "unknown species")

        if not base64_image:
            return jsonify({"error": "base64Image is required"}), 400

        prompt = (
            f"You are a Nature documentary director and field biologist. "
            f"A citizen scientist photographed a {species}.\n\n"
            f"Do ALL of the following in ONE response, interleaving text and a generated image:\n"
            f"1. Write a vivid 3-sentence nature documentary-style narration about this {species}.\n"
            f"2. Generate a cinematic painterly nature illustration of this {species} "
            f"in its natural habitat. Make it dramatic, National Geographic quality.\n"
            f"3. Write a 2-sentence field note in first person as a citizen scientist.\n"
            f"4. On separate lines write:\n"
            f"SCIENTIFIC_NAME: <value>\n"
            f"CONSERVATION_STATUS: <value>\n"
            f"DIET: <value>\n"
            f"HABITAT: <value>\n"
            f"FUN_FACT: <value>"
        )

        image_bytes = base64.b64decode(base64_image)
        resp = client.models.generate_content(
            model=MODEL_IMAGE,
            contents=[
                types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
                types.Part.from_text(text=prompt),
            ],
            config=types.GenerateContentConfig(
                response_modalities=["TEXT", "IMAGE"],
                temperature=0.8,
                max_output_tokens=2000,
            ),
        )

        full_text = ""
        illustration_base64 = ""
        for part in resp.candidates[0].content.parts:
            if hasattr(part, "text") and part.text:
                full_text += part.text
            elif hasattr(part, "inline_data") and part.inline_data:
                illustration_base64 = base64.b64encode(part.inline_data.data).decode()

        scientific_name     = _extract_field("SCIENTIFIC_NAME",     full_text)
        conservation_status = _extract_field("CONSERVATION_STATUS", full_text)
        diet                = _extract_field("DIET",                full_text)
        habitat             = _extract_field("HABITAT",             full_text)
        fun_fact            = _extract_field("FUN_FACT",            full_text)

        lines = [l.strip() for l in full_text.splitlines() if l.strip()]
        skip  = ["SCIENTIFIC_NAME", "CONSERVATION_STATUS", "DIET", "HABITAT", "FUN_FACT"]
        narration_lines, field_note_lines, in_note = [], [], False
        for line in lines:
            if any(line.upper().startswith(lbl) for lbl in skip):
                continue
            if "field note" in line.lower():
                in_note = True
                continue
            (field_note_lines if in_note else narration_lines).append(line)

        narration  = " ".join(narration_lines[:5]).strip() or full_text[:400]
        field_note = " ".join(field_note_lines[:3]).strip() or "A remarkable sighting in the wild."

        audio_base64 = ""
        try:
            tts_resp = client.models.generate_content(
                model=MODEL_TTS,
                contents=narration,
                config=types.GenerateContentConfig(
                    response_modalities=["AUDIO"],
                    speech_config=types.SpeechConfig(
                        voice_config=types.VoiceConfig(
                            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
                        )
                    ),
                ),
            )
            for part in tts_resp.candidates[0].content.parts:
                if hasattr(part, "inline_data") and part.inline_data:
                    wav = _make_wav(part.inline_data.data)
                    audio_base64 = base64.b64encode(wav).decode()
                    break
        except Exception as e:
            print(f"[story] TTS non-fatal: {e}")

        return jsonify({
            "species":            species,
            "scientificName":     scientific_name,
            "conservationStatus": conservation_status,
            "narration":          narration,
            "fieldNote":          field_note,
            "facts":              {"diet": diet, "habitat": habitat, "funFact": fun_fact},
            "illustrationBase64": illustration_base64,
            "audioBase64":        audio_base64,
        })

    except Exception as e:
        print(f"[story] fatal: {e}")
        return jsonify({"error": str(e)}), 500
# ─────────────────────────────────────────────────────────────────────────────
#  Field Guide chat
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/field-guide", methods=["POST"])
def field_guide():
    try:
        data    = request.get_json(force=True)
        message = data.get("message", "")
        history = data.get("history", [])

        system = (
            "You are BioGuide, an expert field naturalist and biodiversity guide. "
            "Help citizen scientists identify species, understand ecosystems, and "
            "learn about conservation. Be concise, warm, and scientifically accurate. "
            "Keep answers under 150 words unless asked for more detail."
        )

        history_text = ""
        for h in history[-6:]:
            role = "User" if h.get("role") == "user" else "BioGuide"
            history_text += f"{role}: {h.get('content', '')}\n"

        full_prompt = f"{system}\n\nConversation:\n{history_text}\nUser: {message}\nBioGuide:"

        resp = client.models.generate_content(
            model=MODEL_TEXT,
            contents=full_prompt,
            config=types.GenerateContentConfig(temperature=0.7, max_output_tokens=300),
        )
        reply = resp.text.strip()
        if reply.startswith("BioGuide:"):
            reply = reply[9:].strip()
        return jsonify({"reply": reply})

    except Exception as e:
        print(f"[field-guide] error: {e}")
        return jsonify({"reply": "Sorry, I could not respond right now."}), 500
# ─────────────────────────────────────────────────────────────────────────────
#  Learn Species TTS
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/learn-species-tts", methods=["POST"])
def learn_species_tts():
    try:
        data   = request.get_json(force=True)
        script = data.get("script", "").strip()
        if not script:
            return jsonify({"error": "script required"}), 400

        print(f"[tts] length={len(script)}")

        try:
            tts_resp = client.models.generate_content(
                model=MODEL_TTS,
                contents=script,
                config=types.GenerateContentConfig(
                    response_modalities=["AUDIO"],
                    speech_config=types.SpeechConfig(
                        voice_config=types.VoiceConfig(
                            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
                        )
                    ),
                ),
            )
            for part in tts_resp.candidates[0].content.parts:
                if hasattr(part, "inline_data") and part.inline_data:
                    wav = _make_wav(part.inline_data.data)
                    return jsonify({
                        "audioBase64": base64.b64encode(wav).decode(),
                        "audioMime":   "audio/wav",
                    })
        except Exception as e:
            print(f"[tts] Gemini TTS failed, falling back: {e}")

        # Fallback: Google Cloud TTS
        import requests as req
        gr = req.post(
            f"https://texttospeech.googleapis.com/v1/text:synthesize?key={GEMINI_API_KEY}",
            headers={"Content-Type": "application/json"},
            json={
                "input": {"text": script[:4900]},
                "voice": {"languageCode": "en-GB", "name": "en-GB-Neural2-B", "ssmlGender": "MALE"},
                "audioConfig": {"audioEncoding": "MP3"},
            },
            timeout=30,
        )
        if gr.status_code == 200:
            return jsonify({"audioBase64": gr.json().get("audioContent", ""), "audioMime": "audio/mpeg"})

        return jsonify({"audioBase64": "", "audioMime": "audio/mpeg"})

    except Exception as e:
        print(f"[tts] fatal: {e}")
        return jsonify({"audioBase64": "", "audioMime": "audio/mpeg"}), 200
# ─────────────────────────────────────────────────────────────────────────────
#  Learn Species — facts + illustration
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/learn-species", methods=["POST"])
def learn_species():
    try:
        data    = request.get_json(force=True)
        species = data.get("species", "unknown species")

        prompt = (
            f"You are a nature encyclopedia. The species is: {species}.\n\n"
            f"Do ALL of the following in ONE response, interleaving a generated image and text:\n"
            f"1. Generate a vivid, cinematic painterly illustration of the {species} in its "
            f"natural habitat. National Geographic quality.\n"
            f"2. After the image, output ONLY these 9 lines. "
            f"STRICT: HABITAT, DIET, SIZE, LIFESPAN must be 5 words or fewer — keywords only.\n"
            f"SCIENTIFIC_NAME: binomial name only\n"
            f"CONSERVATION_STATUS: IUCN status only\n"
            f"HABITAT: e.g. Tropical forests, Asia\n"
            f"DIET: e.g. Deer, wild boar\n"
            f"SIZE: e.g. 3.3m, 300kg\n"
            f"LIFESPAN: e.g. 10-15 years\n"
            f"FUN_FACT: Write ONE single paragraph of 3-4 sentences. Sound EXACTLY like a "
            f"kindergarten teacher talking to 5-year-olds — use words like 'Oh wow!', 'Did you "
            f"know?', 'So cool!', short sentences, lots of excitement and wonder. Pure joy.\n"
            f"HISTORY: Write ONE single paragraph of 3-4 sentences. Same kindergarten teacher "
            f"voice — telling a magical little story about how humans have known and loved this "
            f"animal through history. Simple, warm, enchanting.\n"
            f"THREAT: Write ONE single paragraph of 3-4 sentences. Same kindergarten teacher "
            f"voice — gently explain the danger this animal faces, but end with hope about "
            f"people helping. Caring, simple, uplifting.\n"
        )

        illustration_base64 = ""
        facts_text          = ""

        resp = client.models.generate_content(
            model=MODEL_IMAGE,
            contents=prompt,
            config=types.GenerateContentConfig(
                response_modalities=["TEXT", "IMAGE"],
                temperature=0.4,
            ),
        )
        for part in resp.candidates[0].content.parts:
            if hasattr(part, "text") and part.text:
                facts_text += part.text
            elif hasattr(part, "inline_data") and part.inline_data:
                illustration_base64 = base64.b64encode(part.inline_data.data).decode()

        print(f"[learn] illustration={bool(illustration_base64)}, text={len(facts_text)} chars")

        result = {
            "species":            species,
            "scientificName":     _extract_field("SCIENTIFIC_NAME",     facts_text),
            "conservationStatus": _extract_field("CONSERVATION_STATUS", facts_text),
            "habitat":            _extract_field("HABITAT",             facts_text),
            "diet":               _extract_field("DIET",                facts_text),
            "size":               _extract_field("SIZE",                facts_text),
            "lifespan":           _extract_field("LIFESPAN",            facts_text),
            "funFact":            _extract_field("FUN_FACT",            facts_text, ""),
            "history":            _extract_field("HISTORY",             facts_text, ""),
            "threat":             _extract_field("THREAT",              facts_text, ""),
            "illustrationBase64": illustration_base64,
        }

        # TTS: ONLY fun fact, history, threat — nothing else, no species name, no scientific name
        tts_parts = [p for p in [result['funFact'], result['history'], result['threat']]
                     if p and p not in ('Unknown', 'No data', '')]
        tts_script = ' '.join(tts_parts).strip()
        result["ttsScript"] = tts_script

        audio_base64 = ""
        audio_mime   = "audio/mpeg"
        try:
            tts_resp = client.models.generate_content(
                model=MODEL_TTS,
                contents=tts_script,
                config=types.GenerateContentConfig(
                    response_modalities=["AUDIO"],
                    speech_config=types.SpeechConfig(
                        voice_config=types.VoiceConfig(
                            prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name="Kore")
                        )
                    ),
                ),
            )
            for part in tts_resp.candidates[0].content.parts:
                if hasattr(part, "inline_data") and part.inline_data:
                    wav = _make_wav(part.inline_data.data)
                    audio_base64 = base64.b64encode(wav).decode()
                    audio_mime   = "audio/wav"
                    break
        except Exception as e:
            print(f"[learn] TTS non-fatal: {e}")

        result["audioBase64"] = audio_base64
        result["audioMime"]   = audio_mime
        return jsonify(result)

    except Exception as e:
        print(f"[learn] fatal: {e}")
        traceback.print_exc()
        return jsonify({"error": str(e)}), 500
# ─────────────────────────────────────────────────────────────────────────────
#  Learn Species facts-only fallback
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/learn-species-facts", methods=["POST"])
def learn_species_facts():
    try:
        data    = request.get_json(force=True)
        species = data.get("species", "unknown species")

        prompt = (
            f"Nature encyclopedia facts about: {species}\n\n"
            f"Output ONLY these 9 lines, no extra text:\n"
            f"SCIENTIFIC_NAME: binomial name\n"
            f"CONSERVATION_STATUS: IUCN status\n"
            f"HABITAT: 5 words max\n"
            f"DIET: 5 words max\n"
            f"SIZE: e.g. 3.3m, 300kg\n"
            f"LIFESPAN: e.g. 10-15 years\n"
            f"FUN_FACT: 3-4 sentence engaging paragraph\n"
            f"HISTORY: 3-4 sentence paragraph on cultural/scientific significance\n"
            f"THREAT: 3-4 sentence paragraph on threats and conservation"
        )

        resp = client.models.generate_content(
            model=MODEL_TEXT,
            contents=prompt,
            config=types.GenerateContentConfig(temperature=0.3, max_output_tokens=800),
        )
        t = resp.text
        return jsonify({
            "species":            species,
            "scientificName":     _extract_field("SCIENTIFIC_NAME",     t),
            "conservationStatus": _extract_field("CONSERVATION_STATUS", t),
            "habitat":            _extract_field("HABITAT",             t),
            "diet":               _extract_field("DIET",                t),
            "size":               _extract_field("SIZE",                t),
            "lifespan":           _extract_field("LIFESPAN",            t),
            "funFact":            _extract_field("FUN_FACT",            t, ""),
            "history":            _extract_field("HISTORY",             t, ""),
            "threat":             _extract_field("THREAT",              t, ""),
        })

    except Exception as e:
        return jsonify({"error": str(e)}), 500
# ─────────────────────────────────────────────────────────────────────────────
#  Veo video generation via SDK
# ─────────────────────────────────────────────────────────────────────────────

def _generate_veo_video(species: str) -> str:
    """
    Generate a wildlife video using the Google GenAI SDK (Veo).
    Uses only the species name — no image input.
    Polls via client.operations.get(operation) until done,
    then reads video bytes from operation.response.generated_videos[0].video.video_bytes.
    Falls back to URI download if inline bytes are absent.
    """
    plant_keywords = [
        "flower","tree","plant","fern","moss","mushroom","orchid","rose","oak",
        "pine","palm","cactus","bamboo","grass","lily","tulip","sunflower",
        "mangrove","seaweed","algae","vine","shrub","herb","weed","bush",
        "fungi","lichen","kelp",
    ]
    is_plant = any(k in species.lower() for k in plant_keywords)

    if is_plant:
        prompt = (
            f"A serene nature documentary shot of a {species} in its natural habitat. "
            f"Gentle breeze moves through it, wind rustles the foliage. "
            f"Ambient nature sounds, golden hour lighting. Cinematic, photorealistic."
        )
    else:
        prompt = (
            f"A wildlife documentary close-up of a {species} in its natural habitat. "
            f"The {species} makes its characteristic natural sound — roaring, chirping, "
            f"Natural behaviour, dramatic cinematic lighting. Photorealistic."
        )

    print(f"[video] generate_videos for '{species}' model={MODEL_VEO}")
    print(f"[video] prompt: {prompt}")

    try:
        # ── Start generation ─────────────────────────────────────────────────
        print(f"[video] calling client.models.generate_videos...")
        operation = client.models.generate_videos(
            model=MODEL_VEO,
            prompt=prompt,
            config=types.GenerateVideosConfig(aspect_ratio="16:9"),
        )
        print(f"[video] operation started: name={getattr(operation, 'name', 'N/A')} done={operation.done}")
        print(f"[video] operation type: {type(operation)}")

        # ── Poll until done ──────────────────────────────────────────────────
        for attempt in range(120):  # 120 × 5 s = 10 min max
            time.sleep(5)
            try:
                operation = client.operations.get(operation)
            except Exception as poll_err:
                print(f"[video] poll {attempt+1} error: {poll_err}")
                continue
            print(f"[video] poll {attempt+1}: done={operation.done}")
            if operation.done:
                break

        if not operation.done:
            print("[video] timed out after 10 min")
            return ""

        # ── Inspect full response ─────────────────────────────────────────────
        print(f"[video] operation.done=True")
        print(f"[video] operation.error={getattr(operation, 'error', 'N/A')}")
        print(f"[video] operation.response={operation.response}")
        print(f"[video] operation.response type={type(operation.response)}")

        op_error = getattr(operation, 'error', None)
        if op_error:
            print(f"[video] BLOCKED/ERROR: {op_error}")
            return ""

        if operation.response is None:
            print("[video] response is None — likely blocked silently")
            return ""

        generated = operation.response.generated_videos
        print(f"[video] generated_videos={generated}")
        print(f"[video] generated_videos count={len(generated) if generated else 0}")

        if not generated:
            print("[video] no generated_videos — dumping full response attrs:")
            for attr in dir(operation.response):
                if not attr.startswith('_'):
                    try:
                        val = getattr(operation.response, attr)
                        if not callable(val):
                            print(f"[video]   response.{attr} = {val}")
                    except Exception:
                        pass
            return ""

        video = generated[0].video
        print(f"[video] video object: {video}")
        print(f"[video] video type: {type(video)}")
        print(f"[video] video.uri: {getattr(video, 'uri', 'N/A')}")
        print(f"[video] video.video_bytes present: {bool(getattr(video, 'video_bytes', None))}")
        if getattr(video, 'video_bytes', None):
            print(f"[video] video.video_bytes length: {len(video.video_bytes)}")

        # Inline bytes
        if getattr(video, "video_bytes", None):
            print(f"[video] returning inline bytes: {len(video.video_bytes)}")
            return base64.b64encode(video.video_bytes).decode()

        # URI fallback
        uri = getattr(video, "uri", None)
        if uri:
            print(f"[video] downloading from uri: {uri[:80]}")
            import requests as req
            dl = req.get(
                uri,
                headers={"x-goog-api-key": GEMINI_API_KEY},
                timeout=120,
                allow_redirects=True,
            )
            print(f"[video] download: status={dl.status_code} content-type={dl.headers.get('Content-Type')} size={len(dl.content)}")
            if dl.status_code == 200 and dl.content:
                return base64.b64encode(dl.content).decode()
            print(f"[video] download failed: {dl.text[:300]}")

        print("[video] no bytes available after all attempts")
        return ""

    except Exception as e:
        print(f"[video] EXCEPTION: {e}")
        traceback.print_exc()
        return ""

# ─────────────────────────────────────────────────────────────────────────────
#  Async video job endpoints
# ─────────────────────────────────────────────────────────────────────────────

_video_ops: dict      = {}
_video_ops_lock       = threading.Lock()
@app.route("/generate-video", methods=["POST"])
def generate_video():
    try:
        species = request.get_json(force=True).get("species", "wildlife")
        return jsonify({"videoBase64": _generate_veo_video(species)})
    except Exception as e:
        return jsonify({"videoBase64": "", "error": str(e)}), 200
@app.route("/learn-species-video-start", methods=["POST"])
def learn_species_video_start():
    species = request.get_json(force=True).get("species", "unknown species")
    op_key  = str(uuid.uuid4())

    with _video_ops_lock:
        _video_ops[op_key] = {"done": False, "videoBytes": b"", "error": ""}

    def run():
        print(f"[video-thread] starting for species='{species}'")
        try:
            b64   = _generate_veo_video(species)
            print(f"[video-thread] _generate_veo_video returned, b64 length={len(b64)}")
            vbytes = base64.b64decode(b64) if b64 else b""
            print(f"[video-thread] video bytes={len(vbytes)}")
            with _video_ops_lock:
                _video_ops[op_key] = {"done": True, "videoBytes": vbytes, "error": ""}
        except Exception as e:
            print(f"[video-thread] EXCEPTION: {e}")
            traceback.print_exc()
            with _video_ops_lock:
                _video_ops[op_key] = {"done": True, "videoBytes": b"", "error": str(e)}

    threading.Thread(target=run, daemon=True).start()
    print(f"[video] started op_key={op_key} for '{species}'")
    return jsonify({"opKey": op_key})
@app.route("/learn-species-video-status", methods=["GET"])
def learn_species_video_status():
    op_key = request.args.get("key", "")
    with _video_ops_lock:
        s = _video_ops.get(op_key)
    if s is None:
        return jsonify({"done": False, "error": "unknown op_key"}), 404
    return jsonify({"done": s["done"], "hasVideo": len(s.get("videoBytes", b"")) > 0,
                    "error": s.get("error", "")})
@app.route("/learn-species-video-download", methods=["GET"])
def learn_species_video_download():
    op_key = request.args.get("key", "")
    with _video_ops_lock:
        s = _video_ops.get(op_key)
    if s is None or not s.get("done"):
        return jsonify({"error": "not ready"}), 404
    vbytes = s.get("videoBytes", b"")
    if not vbytes:
        return jsonify({"error": "no video"}), 404
    return Response(vbytes, mimetype="video/mp4",
                    headers={"Content-Length": str(len(vbytes))})
# ─────────────────────────────────────────────────────────────────────────────
#  Infographic
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/learn-species-infographic", methods=["POST"])
def learn_species_infographic():
    try:
        data    = request.get_json(force=True)
        species = data.get("species", "unknown species")

        # Let the model choose any 4 interesting facts freely — not from parsed output
        prompt = (
            f"Create a colourful, fun cartoon-style nature infographic poster about the {species}. "
            f"The design should be bright, modern, and educational — suitable for a nature app. "
            f"Include '{species}' as a large title at the top. "
            f"Draw a cute, detailed cartoon illustration of the {species} as the central focus. "
            f"Pick any 4 interesting facts about the {species} yourself and show them in clearly "
            f"be most surprising or delightful to learn — you decide the categories and values. "
            f"Professional nature app style. "
            f"Text should not overlap the illustration."
        )

        resp = client.models.generate_content(
            model=MODEL_IMAGE,
            contents=prompt,
            config=types.GenerateContentConfig(
                response_modalities=["IMAGE"],
                temperature=0.9,
            ),
        )

        for part in resp.candidates[0].content.parts:
            if hasattr(part, "inline_data") and part.inline_data:
                img_b64 = base64.b64encode(part.inline_data.data).decode()
                print(f"[infographic] image len={len(img_b64)}")
                return jsonify({"imageBase64": img_b64})

        return jsonify({"imageBase64": "", "error": "no image in response"}), 200

    except Exception as e:
        print(f"[infographic] fatal: {e}")
        return jsonify({"imageBase64": "", "error": str(e)}), 200
# ─────────────────────────────────────────────────────────────────────────────
#  Lifecycle Image
# ─────────────────────────────────────────────────────────────────────────────

@app.route("/learn-species-lifecycle", methods=["POST"])
def learn_species_lifecycle():
    try:
        data    = request.get_json(force=True)
        species = data.get("species", "unknown species")

        prompt = (
            f"Create a detailed, labelled lifecycle diagram poster for the {species}. "
            f"The design should be clean, scientific, and educational — suitable for a nature app. "
            f"Include '{species} Life Cycle' as a large title at the top. "
            f"Illustrate every distinct stage of the {species} lifecycle as clearly drawn "
            f"cartoon-style panels arranged in a circular or sequential flow. "
            f"Each stage panel must have a label (e.g. 'Egg', 'Larva', 'Pupa', 'Adult' "
            f"for insects; 'Seed', 'Seedling', 'Sapling', 'Mature Tree' for plants; "
            f"'Birth', 'Juvenile', 'Adult' for mammals — use whatever stages "
            f"are scientifically correct for this species). "
            f"Draw clear arrows between stages showing the direction of the cycle. "
            f"Make the illustrations detailed and accurate. "
            f"No extra text beyond the title, stage illustrations, labels, and arrows."
        )

        resp = client.models.generate_content(
            model=MODEL_IMAGE,
            contents=prompt,
            config=types.GenerateContentConfig(
                response_modalities=["IMAGE"],
                temperature=0.7,
            ),
        )

        for part in resp.candidates[0].content.parts:
            if hasattr(part, "inline_data") and part.inline_data:
                img_b64 = base64.b64encode(part.inline_data.data).decode()
                print(f"[lifecycle] image len={len(img_b64)}")
                return jsonify({"imageBase64": img_b64})

        return jsonify({"imageBase64": "", "error": "no image in response"}), 200

    except Exception as e:
        print(f"[lifecycle] fatal: {e}")
        return jsonify({"imageBase64": "", "error": str(e)}), 200

# ─────────────────────────────────────────────────────────────────────────────

if __name__ == '__main__':
    port = int(os.environ.get('PORT', 8080))
    app.run(host='0.0.0.0', port=port)