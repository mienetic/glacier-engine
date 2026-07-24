//! Dependency-free Rust quick start for the experimental Glacier contract ABI.
//!
//! Link the shared library from its build output, then make it visible to the
//! operating-system loader:
//!
//! macOS:
//!   rustc examples/interop/rust_verify.rs -L native=zig-out/lib -o /tmp/glacier-contract-rust
//!   DYLD_LIBRARY_PATH=zig-out/lib /tmp/glacier-contract-rust
//!
//! Linux:
//!   rustc examples/interop/rust_verify.rs -L native=zig-out/lib -o /tmp/glacier-contract-rust
//!   LD_LIBRARY_PATH=zig-out/lib /tmp/glacier-contract-rust
//!
//! Windows (Command Prompt):
//!   rustc examples\interop\rust_verify.rs -L native=zig-out\lib -o glacier-contract-rust.exe
//!   set PATH=%CD%\zig-out\bin;%PATH%
//!   glacier-contract-rust.exe
//!
//! Pass `--fixtures <directory>` when running outside the repository root.
//! This ABI is experimental and may change before a stable release.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

const OK: u32 = 0;
const ABI_V1: u64 = 1;
const NULL: u32 = 1;
const SIZE: u32 = 2;
const INVALID_ARTIFACT: u32 = 3;
const INVALID_PLAN: u32 = 4;
const INVALID_RESULT: u32 = 5;
const BINDING_MISMATCH: u32 = 6;

#[link(name = "glacier_contract")]
extern "C" {
    fn glacier_contract_abi_v1() -> u64;
    fn glacier_model_contract_verify_v1(
        artifact: *const u8,
        artifact_len: usize,
        plan: *const u8,
        plan_len: usize,
        result: *const u8,
        result_len: usize,
        out_result_root: *mut u8,
    ) -> u32;
}

fn status_name(status: u32) -> &'static str {
    match status {
        OK => "OK",
        NULL => "NULL",
        SIZE => "SIZE",
        INVALID_ARTIFACT => "INVALID_ARTIFACT",
        INVALID_PLAN => "INVALID_PLAN",
        INVALID_RESULT => "INVALID_RESULT",
        BINDING_MISMATCH => "BINDING_MISMATCH",
        _ => "UNKNOWN",
    }
}

enum Command {
    Run(PathBuf),
    Help,
}

fn parse_args() -> Result<Command, String> {
    let mut arguments = env::args_os().skip(1);
    let mut fixture_dir = None;
    while let Some(argument) = arguments.next() {
        if argument == "--fixtures" {
            let value = arguments
                .next()
                .ok_or_else(|| "--fixtures requires a directory".to_owned())?;
            fixture_dir = Some(PathBuf::from(value));
        } else if argument == "--help" || argument == "-h" {
            println!(
                "Usage: rust_verify [--fixtures <directory>]\n\
                 Verifies canonical ModelContract V1 fixtures through the \
                 experimental C ABI."
            );
            return Ok(Command::Help);
        } else {
            return Err(format!("unknown argument: {}", argument.to_string_lossy()));
        }
    }
    Ok(Command::Run(
        fixture_dir.unwrap_or_else(default_fixture_dir),
    ))
}

fn default_fixture_dir() -> PathBuf {
    let from_working_directory = PathBuf::from("examples/interop/fixtures");
    if from_working_directory.is_dir() {
        return from_working_directory;
    }
    Path::new(file!())
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("fixtures")
}

fn decode_hex(text: &str) -> Result<Vec<u8>, String> {
    let compact: String = text
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect();
    if compact.len() % 2 != 0 {
        return Err("hex text contains an incomplete byte".to_owned());
    }
    compact
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let pair = std::str::from_utf8(pair).map_err(|_| "hex text is not ASCII".to_owned())?;
            u8::from_str_radix(pair, 16).map_err(|_| format!("invalid hex byte: {pair}"))
        })
        .collect()
}

fn read_fixture(directory: &Path, name: &str, expected: usize) -> Result<Vec<u8>, String> {
    let path = directory.join(name);
    let text = fs::read_to_string(&path)
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
    let wire = decode_hex(&text)?;
    if wire.len() != expected {
        return Err(format!(
            "{} has {} bytes; expected exactly {expected}",
            path.display(),
            wire.len()
        ));
    }
    Ok(wire)
}

fn run(fixture_dir: &Path) -> Result<(), String> {
    let artifact = read_fixture(fixture_dir, "artifact_manifest_v1.hex", 320)?;
    let plan = read_fixture(fixture_dir, "execution_plan_v1.hex", 768)?;
    let result = read_fixture(fixture_dir, "result_envelope_v1.hex", 768)?;
    let mut result_root = [0_u8; 32];

    let abi = unsafe { glacier_contract_abi_v1() };
    if abi != ABI_V1 {
        return Err(format!(
            "unsupported contract ABI: expected {ABI_V1}, received {abi}"
        ));
    }
    let status = unsafe {
        glacier_model_contract_verify_v1(
            artifact.as_ptr(),
            artifact.len(),
            plan.as_ptr(),
            plan.len(),
            result.as_ptr(),
            result.len(),
            result_root.as_mut_ptr(),
        )
    };
    if status != OK {
        return Err(format!(
            "contract verification failed: {} ({status})",
            status_name(status)
        ));
    }
    if result_root.as_slice() != &result[result.len() - result_root.len()..] {
        return Err("binding returned a root different from the canonical wire".to_owned());
    }

    println!("Glacier contract C ABI (experimental)");
    println!("abi=0x{abi:016x}");
    print!("result_root=");
    for byte in result_root {
        print!("{byte:02x}");
    }
    println!();
    Ok(())
}

fn main() -> ExitCode {
    let fixture_dir = match parse_args() {
        Ok(Command::Run(path)) => path,
        Ok(Command::Help) => return ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::FAILURE;
        }
    };
    match run(&fixture_dir) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::FAILURE
        }
    }
}
