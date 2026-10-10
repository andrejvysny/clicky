#!/usr/bin/env python3
"""Regenerate leanring-buddy/TextInput/Core/LocalModelCatalog+Pins.swift.

Dev tool only (not shipped, Python 3 stdlib). Queries the Hugging Face API for each pinned
repository + revision (metadata only, never weights) and writes a deterministic Swift literal:
files sorted by path, sizes and hashes taken from the API (LFS files carry lfs.sha256, other
files only the git blob SHA-1).

Usage: python3 scripts/generate-model-catalog.py [--check]
  --check  exit 1 if the committed file differs from the regenerated output.
"""
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent.parent / "leanring-buddy/TextInput/Core/LocalModelCatalog+Pins.swift"
WHISPERKIT = ("argmaxinc/whisperkit-coreml", "0f63a7800b00dd0226abd051b906c246e1907482")
CATALOG_VERSION = 1

MLX_TEXT_FILES = {
    "added_tokens.json", "chat_template.jinja", "chat_template.json", "config.json",
    "generation_config.json", "merges.txt", "model.safetensors.index.json",
    "preprocessor_config.json", "special_tokens_map.json", "tokenizer.json",
    "tokenizer_config.json", "video_preprocessor_config.json", "vocab.json",
}
PARAKEET_DIRS = ("Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/", "JointDecisionv3.mlmodelc/")


def mlx_vlm(path):
    return path in MLX_TEXT_FILES or path.endswith(".safetensors")


def s1_mini(path):
    keep = {"LICENSE", "NOTICE", "chat_template.jinja", "config.json", "generation_config.json", "merges.txt",
            "tokenizer.json", "tokenizer_config.json", "vocab.json", "model.safetensors", "model.safetensors.index.json"}
    return path in keep


def parakeet(path):
    return path == "parakeet_vocab.json" or path.startswith(PARAKEET_DIRS)


def whisper(prefix):
    return lambda path: path.startswith(prefix + "/")


# WhisperKit loads its tokenizer from modelFolder/tokenizer.json (ModelUtilities.loadTokenizer search paths);
# without it it downloads openai/whisper-* from the Hub, so the two files are pinned from that repo.
def whisper_tokenizer(repo, revision):
    return [(repo, revision, "tokenizer.json"), (repo, revision, "tokenizer_config.json")]


ENTRIES = [
    dict(id="qwen3-vl-4b-instruct-4bit", name="Qwen3-VL 4B Instruct (MLX 4-bit)", kind="mlxVLM", group="vision",
         repo="lmstudio-community/Qwen3-VL-4B-Instruct-MLX-4bit", rev="552af30c9952c44f1e1a27c7c5810ded58e892bc",
         license="apache-2.0", quant="4-bit MLX", keep=mlx_vlm,
         notes="Default local vision model: screen understanding and pointing."),
    dict(id="qwen3-vl-2b-instruct-4bit", name="Qwen3-VL 2B Instruct (MLX 4-bit)", kind="mlxVLM", group="vision",
         repo="mlx-community/Qwen3-VL-2B-Instruct-4bit", rev="9c4f5209e57b31f4b9dfba735de3fb983739c9cc",
         license="apache-2.0", quant="4-bit MLX", keep=mlx_vlm,
         notes="Smaller vision comparator for debug and low-memory measurement."),
    dict(id="qwen3-vl-8b-instruct-4bit", name="Qwen3-VL 8B Instruct (MLX 4-bit)", kind="mlxVLM", group="vision",
         repo="mlx-community/Qwen3-VL-8B-Instruct-4bit", rev="defcdea7cc7a4b0858fea563cbbce171d328e457",
         license="apache-2.0", quant="4-bit MLX", keep=mlx_vlm,
         notes="On-device assistant candidate: larger vision model for chat, pointing, walkthroughs and writing."),
    dict(id="qwen3-vl-8b-instruct-8bit", name="Qwen3-VL 8B Instruct (MLX 8-bit)", kind="mlxVLM", group="vision",
         repo="mlx-community/Qwen3-VL-8B-Instruct-8bit", rev="a0093b9b5fda6f76ddd4a462c6830ae7c4fe47ec",
         license="apache-2.0", quant="8-bit MLX", keep=mlx_vlm,
         notes="On-device assistant precision comparator; needs a memory budget above the default 45% on 24 GB Macs."),
    dict(id="s1-mini", name="S1-mini (transcript cleanup)", kind="mlxLLM", group="cleanup",
         repo="superwhisper/s1-mini", rev="88f6b15896c73bbb13a3b596e0afe8ea0d5150b4",
         license="other: LICENSE (Apache-2.0 plus a naming clause; model must keep the name \"S1-mini\" by \"Superwhisper\" with that exact capitalization; retain LICENSE and NOTICE)",
         quant="bf16 safetensors (Qwen3-0.6B finetune)", keep=s1_mini,
         notes="Transcript cleanup. Apache-2.0 base plus naming clause per the model card; LICENSE and NOTICE are installed with the weights."),
    dict(id="parakeet-tdt-0.6b-v3-coreml", name="Parakeet TDT 0.6B v3 (Core ML, int8 encoder)", kind="parakeetCoreML", group="speech",
         repo="FluidInference/parakeet-tdt-0.6b-v3-coreml", rev="7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
         install_sub="parakeet-tdt-0.6b-v3-coreml",
         license="cc-by-4.0", quant="Core ML int8 encoder", keep=parakeet,
         notes="Files FluidAudio 0.17.7 loads for AsrModels.loadLocal(from:version: .v3, encoderPrecision: .int8): Preprocessor, Encoder, Decoder, JointDecisionv3 and parakeet_vocab.json. Load with loadLocal(from: runtime directory), which never downloads; load(from:) would also need FluidAudio's .fluidaudio-revision marker."),
    dict(id="whisper-large-v3-turbo-632mb", name="Whisper large-v3 turbo (WhisperKit, 632 MB)", kind="whisperKit", group="speech",
         repo=WHISPERKIT[0], rev=WHISPERKIT[1], source_sub="openai_whisper-large-v3-v20240930_turbo_632MB",
         license="mit", quant="Core ML 632 MB", keep=whisper("openai_whisper-large-v3-v20240930_turbo_632MB"),
         extras=whisper_tokenizer("openai/whisper-large-v3", "06f233fe06e710322aca913c1bc4249a0d71fce1"),
         notes="WhisperKit(modelFolder:, download: false). tokenizer.json and tokenizer_config.json come from openai/whisper-large-v3 (Apache-2.0) and sit next to the model files."),
    dict(id="whisper-small-en-217mb", name="Whisper small.en (WhisperKit, 217 MB)", kind="whisperKit", group="speech",
         repo=WHISPERKIT[0], rev=WHISPERKIT[1], source_sub="openai_whisper-small.en_217MB",
         license="mit", quant="Core ML 217 MB", keep=whisper("openai_whisper-small.en_217MB"),
         extras=whisper_tokenizer("openai/whisper-small.en", "e8727524f962ee844a7319d92be39ac1bd25655a"),
         notes="WhisperKit(modelFolder:, download: false). tokenizer.json and tokenizer_config.json come from openai/whisper-small.en (Apache-2.0) and sit next to the model files."),
]


def fetch_siblings(repo, revision, retries=4):
    url = f"https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true"
    for attempt in range(retries):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                data = json.load(response)
            if data.get("sha") != revision:
                raise SystemExit(f"{repo}: API returned sha {data.get('sha')}, expected {revision}")
            return {s["rfilename"]: s for s in data["siblings"]}
        except (urllib.error.URLError, TimeoutError):
            if attempt == retries - 1:
                raise
            time.sleep(2 ** attempt)


def file_record(sibling, path):
    lfs = sibling.get("lfs")
    record = {"path": path, "size": sibling["size"]}
    if lfs:
        record["sha256"] = lfs["sha256"]
    else:
        record["gitBlobSHA1"] = sibling["blobId"]
    return record


def build_entry(spec):
    siblings = fetch_siblings(spec["repo"], spec["rev"])
    prefix = spec.get("source_sub")
    files = []
    for name in sorted(siblings):
        if spec["keep"](name):
            files.append(file_record(siblings[name], name[len(prefix) + 1:] if prefix else name))
    extras = []
    for repo, rev, path in spec.get("extras", []):
        record = file_record(fetch_siblings(repo, rev)[path], path)
        record["repository"], record["revision"] = repo, rev
        extras.append(record)
    files = sorted(files + extras, key=lambda f: f["path"])
    if not files or len({f["path"] for f in files}) != len(files):
        raise SystemExit(f"{spec['id']}: empty or duplicate file list")
    return files


def swift_string(value):
    return json.dumps(value)


def render_file(record):
    parts = [f"path: {swift_string(record['path'])}", f"size: {record['size']}"]
    for key in ("sha256", "gitBlobSHA1", "repository", "revision"):
        if key in record:
            parts.append(f"{key}: {swift_string(record[key])}")
    return "                .init(" + ", ".join(parts) + "),"


def render(entries_with_files):
    out = ["// GENERATED by scripts/generate-model-catalog.py. Do not edit by hand.",
           "// Pinned from the Hugging Face API (repository + revision); regenerate to change a pin.", "",
           "extension LocalModelCatalog {",
           f"    public static let version = {CATALOG_VERSION}", "",
           "    public static let entries: [LocalModelCatalogEntry] = ["]
    for spec, files in entries_with_files:
        out += ["        LocalModelCatalogEntry(",
                f"            id: {swift_string(spec['id'])},",
                f"            displayName: {swift_string(spec['name'])},",
                f"            kind: .{spec['kind']}, group: .{spec['group']},",
                f"            repository: {swift_string(spec['repo'])},",
                f"            revision: {swift_string(spec['rev'])},",
                f"            sourceSubdirectory: {swift_string(spec['source_sub']) if spec.get('source_sub') else 'nil'},",
                f"            installSubdirectory: {swift_string(spec['install_sub']) if spec.get('install_sub') else 'nil'},",
                f"            license: {swift_string(spec['license'])},",
                f"            quantization: {swift_string(spec['quant'])},",
                f"            notes: {swift_string(spec['notes'])},",
                "            files: ["]
        out += [render_file(f) for f in files]
        out += ["            ]", "        ),"]
    out += ["    ]", "}", ""]
    return "\n".join(out)


def main():
    rendered = render([(spec, build_entry(spec)) for spec in ENTRIES])
    if "--check" in sys.argv:
        sys.exit(0 if OUTPUT.exists() and OUTPUT.read_text() == rendered else 1)
    OUTPUT.write_text(rendered)
    print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()
