"""Podcast generation — outline → transcript → per-speaker TTS → stored audio.

Two-stage LLM (outline model then transcript model) mirrors upstream's
podcast-creator; audio is synthesized per transcript turn with OpenAI TTS, the
mp3 turns are concatenated, and the result is uploaded to Supabase Storage
(bucket ONB_AUDIO_BUCKET). Runs as a background job (onb_jobs) since it is slow.
"""
from __future__ import annotations

import json
import uuid

from . import config, prompts, providers, repository as repo

# OpenAI TTS voice pool — speakers without an explicit voice_id cycle through these.
_VOICE_POOL = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"]


def build_podcast_content(db, notebook_id: str, *, char_budget: int = 16000) -> str:
    """Flatten a notebook's sources/insights/notes into source material."""
    parts: list[str] = []
    used = 0
    for s in repo.list_sources(db, notebook_id=notebook_id):
        body = (s.get("full_text") or "").strip()
        if not body:
            continue
        block = f"# {s.get('title') or 'Source'}\n{body[:4000]}"
        parts.append(block)
        used += len(block)
        if used >= char_budget:
            break
    return "\n\n".join(parts)


def _speaker_names(speaker_profile: dict) -> list[str]:
    speakers = speaker_profile.get("speakers") or []
    names = [sp.get("name") for sp in speakers if sp.get("name")]
    return names or ["Host"]


def _voice_for(speaker_profile: dict, speaker_name: str, idx: int) -> str:
    for sp in (speaker_profile.get("speakers") or []):
        if sp.get("name") == speaker_name and sp.get("voice_id"):
            return sp["voice_id"]
    return _VOICE_POOL[idx % len(_VOICE_POOL)]


def generate_episode(db, episode_id: str, *, job_id: str | None = None) -> dict:
    """Full pipeline for an already-created episode row. Updates status + job."""
    ep = repo.get_episode(db, episode_id)
    if not ep:
        raise ValueError("episode not found")
    if job_id:
        repo.update_job(db, job_id, {"status": "processing"})
    repo.update_episode(db, episode_id, {"status": "processing", "error": None})
    try:
        ep_profile = ep.get("episode_profile") or {}
        sp_profile = ep.get("speaker_profile") or {}
        briefing = ep.get("briefing") or ep_profile.get("default_briefing") or ""
        content = ep.get("content") or ""
        num_segments = int(ep_profile.get("num_segments") or 5)

        # Stage 1 — outline
        outline_raw = providers.chat(
            [{"role": "user", "content": prompts.podcast_outline_user(briefing, content, num_segments)}],
            max_tokens=1500, temperature=0.4,
        )
        outline = _extract_json(outline_raw, default=[])

        # Stage 2 — transcript
        speakers = _speaker_names(sp_profile)
        transcript_raw = providers.chat(
            [{"role": "user", "content": prompts.podcast_transcript_user(
                json.dumps(outline), speakers, briefing)}],
            max_tokens=4000, temperature=0.6,
        )
        transcript = _extract_json(transcript_raw, default=[])
        if not transcript:
            raise ValueError("transcript generation produced no turns")

        repo.update_episode(db, episode_id, {
            "outline": outline, "transcript": transcript,
            "content": _transcript_to_text(transcript),
        })

        # Stage 3 — TTS per turn, concatenated. Voice is keyed on the SPEAKER's
        # stable position (not the turn index) so each speaker keeps one voice.
        # TTS needs OpenAI (Claude has no speech synthesis, and the shared
        # platform key is Anthropic-only). If no TTS provider is configured, the
        # episode still succeeds as TRANSCRIPT-ONLY — the script is written and
        # saved; only the audio is skipped. A missing key must not fail the job.
        try:
            speaker_order = {n: i for i, n in enumerate(speakers)}
            audio = bytearray()
            for turn in transcript:
                text = (turn.get("text") or "").strip()
                if not text:
                    continue
                sp_name = turn.get("speaker") or ""
                voice = _voice_for(sp_profile, sp_name, speaker_order.get(sp_name, 0))
                audio.extend(providers.tts(text, voice=voice))
            audio_url = _upload_audio(db, episode_id, bytes(audio))
        except providers.ProviderError:
            repo.update_episode(db, episode_id, {
                "status": "done", "audio_url": None,
                "error": "Transcript ready. Audio skipped — no TTS provider "
                         "(set OPENAI_API_KEY to generate narration).",
            })
            if job_id:
                repo.update_job(db, job_id, {"status": "done"})
            return repo.get_episode(db, episode_id) or {}

        repo.update_episode(db, episode_id, {"status": "done", "audio_url": audio_url, "error": None})
        if job_id:
            repo.update_job(db, job_id, {"status": "done"})
        return repo.get_episode(db, episode_id) or {}
    except Exception as e:
        msg = str(e)
        repo.update_episode(db, episode_id, {"status": "error", "error": msg})
        if job_id:
            repo.update_job(db, job_id, {"status": "error", "error": msg})
        raise


def _upload_audio(db, episode_id: str, audio: bytes) -> str:
    """Upload mp3 to Supabase Storage; return a public URL. Requires the bucket
    ONB_AUDIO_BUCKET to exist (public)."""
    path = f"{episode_id}/{uuid.uuid4().hex}.mp3"
    bucket = config.ONB_AUDIO_BUCKET
    try:
        storage = db.storage.from_(bucket)
        storage.upload(path, audio, {"content-type": "audio/mpeg", "upsert": "true"})
        return storage.get_public_url(path)
    except Exception as e:
        raise RuntimeError(
            f"audio upload failed (ensure a public Storage bucket '{bucket}' exists): {e}") from e


def _extract_json(raw: str, *, default):
    raw = raw.strip()
    for open_c, close_c in (("[", "]"), ("{", "}")):
        start, end = raw.find(open_c), raw.rfind(close_c)
        if start != -1 and end != -1 and end > start:
            try:
                return json.loads(raw[start:end + 1])
            except Exception:
                continue
    return default


def _transcript_to_text(transcript: list) -> str:
    return "\n\n".join(
        f"{t.get('speaker', 'Speaker')}: {t.get('text', '')}" for t in transcript)
