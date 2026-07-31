use gigatoken_rs::load_tokenizer::tiktoken::load_tiktoken;
use gigatoken_rs::pretokenize::FastR50kPretokenizer;
use std::env;
use std::fs;
use std::hint::black_box;
use std::time::Instant;

fn main() {
    let options = Options::parse(env::args().skip(1).collect());
    let input = fs::read(&options.input_path).expect("failed to read benchmark input");

    let model_start = Instant::now();
    let mut tokenizer = load_tiktoken(&options.model_path).expect("failed to load tokenizer model");
    let model_seconds = model_start.elapsed().as_secs_f64();

    let mut output = Vec::new();
    let cold_start = Instant::now();
    tokenizer.memoized_encode_flat(FastR50kPretokenizer::new(&input), &mut output);
    black_box(&output);
    let cold_seconds = cold_start.elapsed().as_secs_f64();

    let mut warm_durations = Vec::with_capacity(options.iterations);
    for _ in 0..options.iterations {
        output.clear();
        let start = Instant::now();
        tokenizer.memoized_encode_flat(FastR50kPretokenizer::new(&input), &mut output);
        black_box(&output);
        warm_durations.push(start.elapsed().as_secs_f64());
    }
    warm_durations.sort_by(f64::total_cmp);
    let warm_seconds = warm_durations[warm_durations.len() / 2];
    let bytes = input.len();
    let token_checksum = token_checksum(&output);
    println!(
        concat!(
            "{{\n",
            "  \"bytes\": {bytes},\n",
            "  \"coldMegabytesPerSecond\": {cold_mbps},\n",
            "  \"coldSeconds\": {cold_seconds},\n",
            "  \"implementation\": \"gigatoken-rust-0.9.0\",\n",
            "  \"iterations\": {iterations},\n",
            "  \"modelBuildSeconds\": {model_seconds},\n",
            "  \"tokens\": {tokens},\n",
            "  \"tokenChecksum\": \"{token_checksum}\",\n",
            "  \"warmMedianSeconds\": {warm_seconds},\n",
            "  \"warmMegabytesPerSecond\": {warm_mbps}\n",
            "}}"
        ),
        bytes = bytes,
        cold_mbps = bytes as f64 / cold_seconds / 1_000_000.0,
        cold_seconds = cold_seconds,
        iterations = options.iterations,
        model_seconds = model_seconds,
        tokens = output.len(),
        token_checksum = token_checksum,
        warm_seconds = warm_seconds,
        warm_mbps = bytes as f64 / warm_seconds / 1_000_000.0,
    );
}

fn token_checksum(tokens: &[u32]) -> String {
    let mut hash = 0xCBF29CE484222325_u64;
    for token in tokens {
        for byte in token.to_le_bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001B3);
        }
    }
    format!("{hash:x}")
}

struct Options {
    model_path: String,
    input_path: String,
    iterations: usize,
}

impl Options {
    fn parse(arguments: Vec<String>) -> Self {
        let mut model_path = None;
        let mut input_path = None;
        let mut iterations = 5;
        let mut index = 0;
        while index < arguments.len() {
            match arguments[index].as_str() {
                "--model" if index + 1 < arguments.len() => {
                    model_path = Some(arguments[index + 1].clone());
                    index += 2;
                }
                "--input" if index + 1 < arguments.len() => {
                    input_path = Some(arguments[index + 1].clone());
                    index += 2;
                }
                "--iterations" if index + 1 < arguments.len() => {
                    iterations = arguments[index + 1]
                        .parse::<usize>()
                        .expect("iterations must be a positive integer");
                    assert!(iterations > 0, "iterations must be positive");
                    index += 2;
                }
                value => panic!("unknown or incomplete argument: {value}"),
            }
        }
        Self {
            model_path: model_path.expect("--model is required"),
            input_path: input_path.expect("--input is required"),
            iterations,
        }
    }
}
