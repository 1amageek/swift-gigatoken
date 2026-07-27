#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/GigaTokenTests/Fixtures"
MODEL = FIXTURES / "r50k_base.tiktoken"
CORPUS = FIXTURES / "r50k_parity.json"
LONG_CORPUS = FIXTURES / "r50k_long_parity.json"
PATTERN = r"'(?:s|t|re|ve|m|ll|d)| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"
CORPUS_SHA256 = "711f61ef38340890a6ea60d60e8353ed9be67e2c37e7ad18baf832a4517c0134"
LONG_CORPUS_SHA256 = "c83eba174977445f1d674cb9c7cb05e9b3ebc5d20a6ffee29e965fb10a074ced"
LONG_CORPUS_BYTE_COUNT = 110_126
LONG_CORPUS_TOKEN_COUNT = 47_228


def alphabetic_label(value: int) -> str:
    label = []
    while True:
        label.append(chr(ord("a") + value % 26))
        value //= 26
        if value == 0:
            return "".join(reversed(label))


def long_parity_text() -> str:
    segments = []
    for index in range(2_048):
        label = alphabetic_label(index)
        segments.append(
            f" short{label} ultralongpretokensequence{label} 日本語{index} !\n"
        )
    text = "".join(segments)
    if len(text.encode()) <= 65_536:
        raise RuntimeError("Long parity fixture must exceed 64 KiB")
    return text


def verify_pinned_fixture(path: Path, expected_sha256: str) -> None:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected_sha256:
        raise SystemExit(
            f"Pinned fixture digest differs for {path}: {digest} != {expected_sha256}"
        )


def check_pinned_fixtures() -> None:
    verify_pinned_fixture(CORPUS, CORPUS_SHA256)
    verify_pinned_fixture(LONG_CORPUS, LONG_CORPUS_SHA256)
    long_fixture = json.loads(LONG_CORPUS.read_text())
    text = long_fixture.get("text")
    tokens = long_fixture.get("tokens")
    if text != long_parity_text():
        raise SystemExit(f"Long parity input is stale: {LONG_CORPUS}")
    if len(text.encode()) != LONG_CORPUS_BYTE_COUNT:
        raise SystemExit(f"Long parity byte count differs: {LONG_CORPUS}")
    if not isinstance(tokens, list) or len(tokens) != LONG_CORPUS_TOKEN_COUNT:
        raise SystemExit(f"Long parity token count differs: {LONG_CORPUS}")
    print("r50k-parity: pinned fixture digests verified")
    print(
        "r50k-long-parity: verified "
        f"{LONG_CORPUS_BYTE_COUNT} bytes and {LONG_CORPUS_TOKEN_COUNT} tokens"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--write", action="store_true")
    operation.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    if arguments.check:
        check_pinned_fixtures()
        return

    try:
        import tiktoken
        from tiktoken.load import load_tiktoken_bpe
    except ModuleNotFoundError as error:
        raise SystemExit(
            "Reference verification requires Scripts/requirements-generation.txt; "
            "use --check for dependency-free pinned-fixture validation"
        ) from error

    fixtures = json.loads(CORPUS.read_text())
    encoding = tiktoken.Encoding(
        name="swift-gigatoken-r50k-parity",
        pat_str=PATTERN,
        mergeable_ranks=load_tiktoken_bpe(str(MODEL)),
        special_tokens={"<|endoftext|>": 50256},
    )
    generated = [
        {"text": fixture["text"], "tokens": encoding.encode_ordinary(fixture["text"])}
        for fixture in fixtures
    ]
    long_generated = {
        "text": long_parity_text(),
        "tokens": encoding.encode_ordinary(long_parity_text()),
    }
    if arguments.write:
        CORPUS.write_text(json.dumps(generated, ensure_ascii=False, separators=(",", ":")))
        LONG_CORPUS.write_text(
            json.dumps(long_generated, ensure_ascii=False, separators=(",", ":"))
        )
        print(f"r50k-parity: wrote {CORPUS}")
        print(f"r50k-long-parity: wrote {LONG_CORPUS}")
        return
    if generated != fixtures:
        raise SystemExit(f"Parity fixture is stale: {CORPUS}")
    long_fixture = json.loads(LONG_CORPUS.read_text())
    if long_generated != long_fixture:
        raise SystemExit(f"Long parity fixture is stale: {LONG_CORPUS}")
    print(f"r50k-parity: verified {len(fixtures)} fixtures")
    print(
        "r50k-long-parity: verified "
        f"{len(long_generated['text'].encode())} bytes and "
        f"{len(long_generated['tokens'])} tokens"
    )


if __name__ == "__main__":
    main()
