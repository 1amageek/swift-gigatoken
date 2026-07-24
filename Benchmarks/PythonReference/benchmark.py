#!/usr/bin/env python3

import argparse
import gc
import importlib.metadata
import json
import time
from pathlib import Path
from typing import Callable


GPT2_REVISION = "607a30d783dfa663caf39e06633721c8d4cfcd7e"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--implementation", choices=("tiktoken", "huggingface"), required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--iterations", type=int, required=True)
    arguments = parser.parse_args()
    if arguments.iterations <= 0:
        parser.error("--iterations must be greater than zero")
    return arguments


def make_encoder(implementation: str) -> tuple[str, Callable[[str], list[int]]]:
    if implementation == "tiktoken":
        import tiktoken

        encoding = tiktoken.get_encoding("r50k_base")
        version = importlib.metadata.version("tiktoken")
        return f"openai-tiktoken-{version}", encoding.encode_ordinary

    from tokenizers import Tokenizer

    tokenizer = Tokenizer.from_pretrained(
        "openai-community/gpt2",
        revision=GPT2_REVISION,
    )
    version = importlib.metadata.version("tokenizers")

    def encode(text: str) -> list[int]:
        return tokenizer.encode(text, add_special_tokens=False).ids

    return f"huggingface-tokenizers-{version}", encode


def token_checksum(tokens: list[int]) -> str:
    value = 0xCBF29CE484222325
    for token in tokens:
        for byte in int(token).to_bytes(4, byteorder="little"):
            value ^= byte
            value = (value * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{value:x}"


def main() -> None:
    arguments = parse_arguments()
    input_bytes = Path(arguments.input).read_bytes()
    text = input_bytes.decode("utf-8")
    implementation, encode = make_encoder(arguments.implementation)

    cold_start = time.perf_counter()
    tokens = encode(text)
    cold_seconds = time.perf_counter() - cold_start

    warm_durations: list[float] = []
    for _ in range(arguments.iterations):
        del tokens
        gc.collect()
        start = time.perf_counter()
        tokens = encode(text)
        warm_durations.append(time.perf_counter() - start)
    warm_durations.sort()
    warm_seconds = warm_durations[len(warm_durations) // 2]

    print(
        json.dumps(
            {
                "implementation": implementation,
                "bytes": len(input_bytes),
                "tokens": len(tokens),
                "tokenChecksum": token_checksum(tokens),
                "coldSeconds": cold_seconds,
                "coldMegabytesPerSecond": len(input_bytes) / cold_seconds / 1_000_000,
                "warmMedianSeconds": warm_seconds,
                "warmMegabytesPerSecond": len(input_bytes) / warm_seconds / 1_000_000,
                "iterations": arguments.iterations,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
