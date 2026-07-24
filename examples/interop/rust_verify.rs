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
const OUT_OF_RANGE: u32 = 7;
const INVALID_QUERY: u32 = 8;

const SUPPORT_REGISTRY_ABI_V1: u64 = 0x4752_5352_0000_0001;
const SUPPORT_PROFILE_COUNT_V1: u64 = 8;
const SUPPORT_PROFILE_VISION_ENCODER: u64 = 0x4756_454e_0000_0001;
const SUPPORT_LIFECYCLE_STATELESS: u64 = 1;
const SUPPORT_EVIDENCE_RETAINED_REFERENCE_FIXTURE: u64 = 1;
const MODEL_FAMILY_VISION_UNDERSTANDING: u64 = 3;
const MODEL_FAMILY_AUDIO_UNDERSTANDING: u64 = 4;
const MODEL_OPERATION_ENCODE: u64 = 3;
const MODEL_OPERATION_TRANSCRIBE: u64 = 6;
const MODEL_INPUT_IMAGE_FEATURE_U8: u64 = 3;
const MODEL_INPUT_AUDIO_FEATURE_I16: u64 = 4;
const MODEL_OUTPUT_EMBEDDING_I32: u64 = 2;
const MODEL_OUTPUT_TRANSCRIPT: u64 = 5;
const NUMERICAL_EXACT_INTEGER: u64 = 1;
const SUPPORT_UNSUPPORTED_NONE: u64 = 0;
const SUPPORT_UNSUPPORTED_CAPABILITIES: u64 = 7;
const SUPPORT_MASK_AUDIO_TRANSCRIPT: u64 = 1 << 2;
const SUPPORT_MASK_STATEFUL_TRANSCRIPT: u64 = 1 << 3;
const SUPPORT_MASK_TRANSCRIPT: u64 =
    SUPPORT_MASK_AUDIO_TRANSCRIPT | SUPPORT_MASK_STATEFUL_TRANSCRIPT;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
struct ModelSupportProfileV1 {
    profile_abi: u64,
    lifecycle: u64,
    evidence: u64,
    family: u64,
    operation: u64,
    input_kind: u64,
    output_kind: u64,
    numerical_policy: u64,
    max_batch_items: u64,
    max_input_features: u64,
    max_output_dimensions: u64,
    allowed_capabilities: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
struct ModelSupportQueryV1 {
    family: u64,
    operation: u64,
    input_kind: u64,
    output_kind: u64,
    numerical_policy: u64,
    batch_items: u64,
    input_features: u64,
    output_dimensions: u64,
    required_capabilities: u64,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
#[repr(C)]
struct ModelSupportResultV1 {
    compatible: u64,
    unsupported_reason: u64,
    matching_profile_mask: u64,
}

const _: [(); 96] = [(); std::mem::size_of::<ModelSupportProfileV1>()];
const _: [(); 72] = [(); std::mem::size_of::<ModelSupportQueryV1>()];
const _: [(); 24] = [(); std::mem::size_of::<ModelSupportResultV1>()];

const FIRST_SUPPORT_PROFILE_V1: ModelSupportProfileV1 = ModelSupportProfileV1 {
    profile_abi: SUPPORT_PROFILE_VISION_ENCODER,
    lifecycle: SUPPORT_LIFECYCLE_STATELESS,
    evidence: SUPPORT_EVIDENCE_RETAINED_REFERENCE_FIXTURE,
    family: MODEL_FAMILY_VISION_UNDERSTANDING,
    operation: MODEL_OPERATION_ENCODE,
    input_kind: MODEL_INPUT_IMAGE_FEATURE_U8,
    output_kind: MODEL_OUTPUT_EMBEDDING_I32,
    numerical_policy: NUMERICAL_EXACT_INTEGER,
    max_batch_items: 64,
    max_input_features: 65_536,
    max_output_dimensions: 16_384,
    allowed_capabilities: 0,
};

#[link(name = "glacier_contract")]
extern "C" {
    fn glacier_contract_abi_v1() -> u64;
    fn glacier_model_support_registry_abi_v1() -> u64;
    fn glacier_model_support_profile_count_v1() -> u64;
    fn glacier_model_support_profile_get_v1(
        index: u64,
        out_profile: *mut ModelSupportProfileV1,
        out_profile_size: usize,
    ) -> u32;
    fn glacier_model_support_query_v1(
        query: *const ModelSupportQueryV1,
        query_size: usize,
        out_result: *mut ModelSupportResultV1,
        out_result_size: usize,
    ) -> u32;
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
        OUT_OF_RANGE => "OUT_OF_RANGE",
        INVALID_QUERY => "INVALID_QUERY",
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

    let registry_abi = unsafe { glacier_model_support_registry_abi_v1() };
    if registry_abi != SUPPORT_REGISTRY_ABI_V1 {
        return Err(format!(
            "unsupported model-support registry ABI: expected \
             0x{SUPPORT_REGISTRY_ABI_V1:016x}, received 0x{registry_abi:016x}"
        ));
    }
    let profile_count = unsafe { glacier_model_support_profile_count_v1() };
    if profile_count != SUPPORT_PROFILE_COUNT_V1 {
        return Err(format!(
            "unexpected model-support profile count: expected \
             {SUPPORT_PROFILE_COUNT_V1}, received {profile_count}"
        ));
    }

    let mut profiles = Vec::with_capacity(profile_count as usize);
    for index in 0..profile_count {
        let mut profile = ModelSupportProfileV1::default();
        let status = unsafe {
            glacier_model_support_profile_get_v1(
                index,
                &mut profile,
                std::mem::size_of::<ModelSupportProfileV1>(),
            )
        };
        if status != OK {
            return Err(format!(
                "support profile {index} failed: {} ({status})",
                status_name(status)
            ));
        }
        if profiles
            .iter()
            .any(|seen: &ModelSupportProfileV1| seen.profile_abi == profile.profile_abi)
        {
            return Err("model-support profile ABI values are not unique".to_owned());
        }
        profiles.push(profile);
    }
    if profiles.first() != Some(&FIRST_SUPPORT_PROFILE_V1) {
        return Err("first model-support profile does not match V1".to_owned());
    }

    let mut transcript_query = ModelSupportQueryV1 {
        family: MODEL_FAMILY_AUDIO_UNDERSTANDING,
        operation: MODEL_OPERATION_TRANSCRIBE,
        input_kind: MODEL_INPUT_AUDIO_FEATURE_I16,
        output_kind: MODEL_OUTPUT_TRANSCRIPT,
        numerical_policy: NUMERICAL_EXACT_INTEGER,
        batch_items: 1,
        input_features: 1,
        output_dimensions: 1,
        required_capabilities: 0,
    };
    let mut transcript_result = ModelSupportResultV1::default();
    let status = unsafe {
        glacier_model_support_query_v1(
            &transcript_query,
            std::mem::size_of::<ModelSupportQueryV1>(),
            &mut transcript_result,
            std::mem::size_of::<ModelSupportResultV1>(),
        )
    };
    if status != OK {
        return Err(format!(
            "transcript support query failed: {} ({status})",
            status_name(status)
        ));
    }
    if transcript_result
        != (ModelSupportResultV1 {
            compatible: 1,
            unsupported_reason: SUPPORT_UNSUPPORTED_NONE,
            matching_profile_mask: SUPPORT_MASK_TRANSCRIPT,
        })
    {
        return Err("transcript support query did not match both V1 profiles".to_owned());
    }

    transcript_query.required_capabilities = 1;
    let mut unsupported_result = ModelSupportResultV1::default();
    let status = unsafe {
        glacier_model_support_query_v1(
            &transcript_query,
            std::mem::size_of::<ModelSupportQueryV1>(),
            &mut unsupported_result,
            std::mem::size_of::<ModelSupportResultV1>(),
        )
    };
    if status != OK {
        return Err(format!(
            "unsupported capability query failed: {} ({status})",
            status_name(status)
        ));
    }
    if unsupported_result
        != (ModelSupportResultV1 {
            compatible: 0,
            unsupported_reason: SUPPORT_UNSUPPORTED_CAPABILITIES,
            matching_profile_mask: 0,
        })
    {
        return Err(
            "unsupported capability query did not return the explicit V1 reason".to_owned(),
        );
    }

    println!("Glacier contract C ABI (experimental)");
    println!("abi=0x{abi:016x}");
    print!("result_root=");
    for byte in result_root {
        print!("{byte:02x}");
    }
    println!();
    println!(
        "profile_count={profile_count} transcript_mask=0x{:016x}",
        transcript_result.matching_profile_mask
    );
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
