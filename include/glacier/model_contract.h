#ifndef GLACIER_MODEL_CONTRACT_H
#define GLACIER_MODEL_CONTRACT_H

/*
 * EXPERIMENTAL: This allocation-free C ABI may change before it is declared
 * stable. It verifies canonical Model Contract V1 wires and queries the
 * retained reference-fixture support registry; it does not expose
 * compiler-specific Zig struct layouts.
 */

#include <stddef.h>
#include <stdint.h>

#if !defined(GLACIER_MODEL_CONTRACT_API)
#  if defined(_WIN32)
#    if defined(GLACIER_MODEL_CONTRACT_STATIC)
#      define GLACIER_MODEL_CONTRACT_API
#    elif defined(GLACIER_MODEL_CONTRACT_BUILD)
#      define GLACIER_MODEL_CONTRACT_API __declspec(dllexport)
#    else
#      define GLACIER_MODEL_CONTRACT_API __declspec(dllimport)
#    endif
#  elif defined(__GNUC__) || defined(__clang__)
#    define GLACIER_MODEL_CONTRACT_API \
        __attribute__((visibility("default")))
#  else
#    define GLACIER_MODEL_CONTRACT_API
#  endif
#endif

#define GLACIER_MODEL_CONTRACT_EXPERIMENTAL 1
#define GLACIER_CONTRACT_ABI_V1 UINT64_C(1)
#define GLACIER_MODEL_SUPPORT_REGISTRY_ABI_V1 \
    UINT64_C(0x4752535200000001)

#define GLACIER_ARTIFACT_MANIFEST_V1_SIZE ((size_t)320)
#define GLACIER_EXECUTION_PLAN_V1_SIZE ((size_t)768)
#define GLACIER_RESULT_ENVELOPE_V1_SIZE ((size_t)768)
#define GLACIER_MODEL_CONTRACT_ROOT_V1_SIZE ((size_t)32)
#define GLACIER_MODEL_SUPPORT_PROFILE_V1_SIZE ((size_t)96)
#define GLACIER_MODEL_SUPPORT_QUERY_V1_SIZE ((size_t)72)
#define GLACIER_MODEL_SUPPORT_RESULT_V1_SIZE ((size_t)24)
#define GLACIER_MODEL_SUPPORT_PROFILE_COUNT_V1 UINT64_C(8)

#define GLACIER_MODEL_CONTRACT_OK UINT32_C(0)
#define GLACIER_MODEL_CONTRACT_NULL_ARGUMENT UINT32_C(1)
#define GLACIER_MODEL_CONTRACT_INVALID_SIZE UINT32_C(2)
#define GLACIER_MODEL_CONTRACT_INVALID_ARTIFACT UINT32_C(3)
#define GLACIER_MODEL_CONTRACT_INVALID_PLAN UINT32_C(4)
#define GLACIER_MODEL_CONTRACT_INVALID_RESULT UINT32_C(5)
#define GLACIER_MODEL_CONTRACT_BINDING_MISMATCH UINT32_C(6)
#define GLACIER_MODEL_CONTRACT_OUT_OF_RANGE UINT32_C(7)
#define GLACIER_MODEL_CONTRACT_INVALID_QUERY UINT32_C(8)

#define GLACIER_MODEL_FAMILY_AUTOREGRESSIVE UINT64_C(1)
#define GLACIER_MODEL_FAMILY_STATELESS_ENCODER UINT64_C(2)
#define GLACIER_MODEL_FAMILY_VISION_UNDERSTANDING UINT64_C(3)
#define GLACIER_MODEL_FAMILY_AUDIO_UNDERSTANDING UINT64_C(4)
#define GLACIER_MODEL_FAMILY_SPEECH_GENERATION UINT64_C(5)
#define GLACIER_MODEL_FAMILY_VIDEO_UNDERSTANDING UINT64_C(6)
#define GLACIER_MODEL_FAMILY_IMAGE_GENERATION UINT64_C(7)
#define GLACIER_MODEL_FAMILY_VIDEO_GENERATION UINT64_C(8)
#define GLACIER_MODEL_FAMILY_AUDIO_GENERATION UINT64_C(9)
#define GLACIER_MODEL_FAMILY_MULTIMODAL_FUSION UINT64_C(10)
#define GLACIER_MODEL_FAMILY_AGENT_POLICY UINT64_C(11)
#define GLACIER_MODEL_FAMILY_RETRIEVAL UINT64_C(12)
#define GLACIER_MODEL_FAMILY_TIME_SERIES UINT64_C(13)
#define GLACIER_MODEL_FAMILY_GRAPH_SCIENTIFIC UINT64_C(14)
#define GLACIER_MODEL_FAMILY_ROUTED_MODEL UINT64_C(15)
#define GLACIER_MODEL_FAMILY_ADAPTER_COMPOSITION UINT64_C(16)
#define GLACIER_MODEL_FAMILY_PROVIDER_HOSTED UINT64_C(17)

#define GLACIER_MODEL_OPERATION_PREFILL UINT64_C(1)
#define GLACIER_MODEL_OPERATION_DECODE_NEXT UINT64_C(2)
#define GLACIER_MODEL_OPERATION_ENCODE UINT64_C(3)
#define GLACIER_MODEL_OPERATION_CLASSIFY UINT64_C(4)
#define GLACIER_MODEL_OPERATION_RERANK UINT64_C(5)
#define GLACIER_MODEL_OPERATION_TRANSCRIBE UINT64_C(6)
#define GLACIER_MODEL_OPERATION_SYNTHESIZE UINT64_C(7)
#define GLACIER_MODEL_OPERATION_DIFFUSE_STEP UINT64_C(8)
#define GLACIER_MODEL_OPERATION_DETECT UINT64_C(9)
#define GLACIER_MODEL_OPERATION_SEGMENT UINT64_C(10)
#define GLACIER_MODEL_OPERATION_ROUTE UINT64_C(11)
#define GLACIER_MODEL_OPERATION_SELECT_ACTION UINT64_C(12)

#define GLACIER_MODEL_INPUT_TOKEN_IDS UINT64_C(1)
#define GLACIER_MODEL_INPUT_DENSE_TENSOR UINT64_C(2)
#define GLACIER_MODEL_INPUT_IMAGE_FEATURE_U8 UINT64_C(3)
#define GLACIER_MODEL_INPUT_AUDIO_FEATURE_I16 UINT64_C(4)
#define GLACIER_MODEL_INPUT_VIDEO_FEATURE_U8 UINT64_C(5)
#define GLACIER_MODEL_INPUT_LATENT_TENSOR UINT64_C(6)
#define GLACIER_MODEL_INPUT_TYPED_RECORD UINT64_C(7)

#define GLACIER_MODEL_OUTPUT_TOKEN_SCORES UINT64_C(1)
#define GLACIER_MODEL_OUTPUT_EMBEDDING_I32 UINT64_C(2)
#define GLACIER_MODEL_OUTPUT_CLASS_SCORES UINT64_C(3)
#define GLACIER_MODEL_OUTPUT_RANKED_ITEMS UINT64_C(4)
#define GLACIER_MODEL_OUTPUT_TRANSCRIPT UINT64_C(5)
#define GLACIER_MODEL_OUTPUT_MEDIA_CHUNK UINT64_C(6)
#define GLACIER_MODEL_OUTPUT_DETECTION_SET UINT64_C(7)
#define GLACIER_MODEL_OUTPUT_SEGMENTATION_MASK UINT64_C(8)
#define GLACIER_MODEL_OUTPUT_TYPED_ACTION UINT64_C(9)
#define GLACIER_MODEL_OUTPUT_VIDEO_SEGMENT UINT64_C(10)
#define GLACIER_MODEL_OUTPUT_TOKEN_IDS UINT64_C(11)

#define GLACIER_NUMERICAL_EXACT_INTEGER UINT64_C(1)
#define GLACIER_NUMERICAL_STRICT_FLOAT32 UINT64_C(2)
#define GLACIER_NUMERICAL_BOUNDED_FLOAT32 UINT64_C(3)
#define GLACIER_NUMERICAL_IMPLEMENTATION_DEFINED UINT64_C(4)

#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_NONE UINT64_C(0)
#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_FAMILY UINT64_C(1)
#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_OPERATION UINT64_C(2)
#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_INPUT_KIND UINT64_C(3)
#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_OUTPUT_KIND UINT64_C(4)
#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_NUMERICAL_POLICY UINT64_C(5)
#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_DIMENSIONS UINT64_C(6)
#define GLACIER_MODEL_SUPPORT_UNSUPPORTED_CAPABILITIES UINT64_C(7)

#define GLACIER_MODEL_SUPPORT_LIFECYCLE_STATELESS UINT64_C(1)
#define GLACIER_MODEL_SUPPORT_LIFECYCLE_STATEFUL UINT64_C(2)
#define GLACIER_MODEL_SUPPORT_EVIDENCE_RETAINED_REFERENCE_FIXTURE UINT64_C(1)

#define GLACIER_MODEL_SUPPORT_PROFILE_VISION_ENCODER \
    UINT64_C(0x4756454e00000001)
#define GLACIER_MODEL_SUPPORT_PROFILE_AUDIO_WINDOW \
    UINT64_C(0x4741574500000001)
#define GLACIER_MODEL_SUPPORT_PROFILE_TEMPORAL_VIDEO \
    UINT64_C(0x4754564500000001)
#define GLACIER_MODEL_SUPPORT_PROFILE_AUDIO_TRANSCRIPT \
    UINT64_C(0x4154524e00000001)
#define GLACIER_MODEL_SUPPORT_PROFILE_STATEFUL_TRANSCRIPT \
    UINT64_C(0x53545254524e0001)
#define GLACIER_MODEL_SUPPORT_PROFILE_VIDEO_SEGMENT \
    UINT64_C(0x4756534100000001)
#define GLACIER_MODEL_SUPPORT_PROFILE_STATEFUL_VIDEO \
    UINT64_C(0x5354565646520001)
#define GLACIER_MODEL_SUPPORT_PROFILE_LATENT_STEP \
    UINT64_C(0x474c415400000001)

#define GLACIER_MODEL_SUPPORT_INDEX_VISION_ENCODER UINT64_C(0)
#define GLACIER_MODEL_SUPPORT_INDEX_AUDIO_WINDOW UINT64_C(1)
#define GLACIER_MODEL_SUPPORT_INDEX_AUDIO_TRANSCRIPT UINT64_C(2)
#define GLACIER_MODEL_SUPPORT_INDEX_STATEFUL_TRANSCRIPT UINT64_C(3)
#define GLACIER_MODEL_SUPPORT_INDEX_TEMPORAL_VIDEO UINT64_C(4)
#define GLACIER_MODEL_SUPPORT_INDEX_VIDEO_SEGMENT UINT64_C(5)
#define GLACIER_MODEL_SUPPORT_INDEX_STATEFUL_VIDEO UINT64_C(6)
#define GLACIER_MODEL_SUPPORT_INDEX_LATENT_STEP UINT64_C(7)

#define GLACIER_MODEL_SUPPORT_MASK_VISION_ENCODER \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_VISION_ENCODER)
#define GLACIER_MODEL_SUPPORT_MASK_AUDIO_WINDOW \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_AUDIO_WINDOW)
#define GLACIER_MODEL_SUPPORT_MASK_TEMPORAL_VIDEO \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_TEMPORAL_VIDEO)
#define GLACIER_MODEL_SUPPORT_MASK_AUDIO_TRANSCRIPT \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_AUDIO_TRANSCRIPT)
#define GLACIER_MODEL_SUPPORT_MASK_STATEFUL_TRANSCRIPT \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_STATEFUL_TRANSCRIPT)
#define GLACIER_MODEL_SUPPORT_MASK_VIDEO_SEGMENT \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_VIDEO_SEGMENT)
#define GLACIER_MODEL_SUPPORT_MASK_STATEFUL_VIDEO \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_STATEFUL_VIDEO)
#define GLACIER_MODEL_SUPPORT_MASK_LATENT_STEP \
    (UINT64_C(1) << GLACIER_MODEL_SUPPORT_INDEX_LATENT_STEP)

typedef struct glacier_model_support_profile_v1 {
    uint64_t profile_abi;
    uint64_t lifecycle;
    uint64_t evidence;
    uint64_t family;
    uint64_t operation;
    uint64_t input_kind;
    uint64_t output_kind;
    uint64_t numerical_policy;
    uint64_t max_batch_items;
    uint64_t max_input_features;
    uint64_t max_output_dimensions;
    uint64_t allowed_capabilities;
} glacier_model_support_profile_v1_t;

typedef struct glacier_model_support_query_v1 {
    uint64_t family;
    uint64_t operation;
    uint64_t input_kind;
    uint64_t output_kind;
    uint64_t numerical_policy;
    uint64_t batch_items;
    uint64_t input_features;
    uint64_t output_dimensions;
    uint64_t required_capabilities;
} glacier_model_support_query_v1_t;

typedef struct glacier_model_support_result_v1 {
    uint64_t compatible;
    uint64_t unsupported_reason;
    uint64_t matching_profile_mask;
} glacier_model_support_result_v1_t;

#if defined(__cplusplus)
static_assert(
    sizeof(glacier_model_support_profile_v1_t) ==
        GLACIER_MODEL_SUPPORT_PROFILE_V1_SIZE,
    "glacier_model_support_profile_v1 layout changed");
static_assert(
    sizeof(glacier_model_support_query_v1_t) ==
        GLACIER_MODEL_SUPPORT_QUERY_V1_SIZE,
    "glacier_model_support_query_v1 layout changed");
static_assert(
    sizeof(glacier_model_support_result_v1_t) ==
        GLACIER_MODEL_SUPPORT_RESULT_V1_SIZE,
    "glacier_model_support_result_v1 layout changed");
#else
_Static_assert(
    sizeof(glacier_model_support_profile_v1_t) ==
        GLACIER_MODEL_SUPPORT_PROFILE_V1_SIZE,
    "glacier_model_support_profile_v1 layout changed");
_Static_assert(
    sizeof(glacier_model_support_query_v1_t) ==
        GLACIER_MODEL_SUPPORT_QUERY_V1_SIZE,
    "glacier_model_support_query_v1 layout changed");
_Static_assert(
    sizeof(glacier_model_support_result_v1_t) ==
        GLACIER_MODEL_SUPPORT_RESULT_V1_SIZE,
    "glacier_model_support_result_v1 layout changed");
#endif

#ifdef __cplusplus
extern "C" {
#endif

GLACIER_MODEL_CONTRACT_API uint64_t glacier_contract_abi_v1(void);
GLACIER_MODEL_CONTRACT_API uint64_t
glacier_model_support_registry_abi_v1(void);

/*
 * Verifies the three canonical wires and every field that binds the artifact
 * to the plan and the plan to the result. On any failure, out_result_root is
 * zeroed when it is non-null. Validation finishes before writing the output,
 * so out_result_root may point to the final 32 bytes of result_wire for a
 * zero-copy root check. No memory is allocated and no input is retained.
 */
GLACIER_MODEL_CONTRACT_API uint32_t glacier_model_contract_verify_v1(
    const uint8_t *artifact_wire,
    size_t artifact_wire_size,
    const uint8_t *plan_wire,
    size_t plan_wire_size,
    const uint8_t *result_wire,
    size_t result_wire_size,
    uint8_t out_result_root[32]);

/*
 * Enumerates append-only retained reference-fixture compatibility profiles.
 * A profile describes a contract shape and resource bound only. It is not a
 * claim that a production model, loader, backend, accelerator, or current host
 * can execute that shape.
 */
GLACIER_MODEL_CONTRACT_API uint64_t
glacier_model_support_profile_count_v1(void);

/*
 * Copies one fixed-width profile by stable V1 index. On an out-of-range index,
 * a correctly sized output is zeroed and OUT_OF_RANGE is returned. No pointer
 * into library-owned storage is exposed or retained.
 */
GLACIER_MODEL_CONTRACT_API uint32_t
glacier_model_support_profile_get_v1(
    uint64_t index,
    glacier_model_support_profile_v1_t *out_profile,
    size_t out_profile_size);

/*
 * Evaluates the typed contract fields and bounds against every profile.
 * Unsupported queries are successful ABI calls with compatible=0 and a named
 * unsupported_reason. Unknown enum values return INVALID_QUERY. A correctly
 * sized result is zeroed before any validation failure. The query and result
 * storage may overlap because the complete query is copied before output.
 */
GLACIER_MODEL_CONTRACT_API uint32_t glacier_model_support_query_v1(
    const glacier_model_support_query_v1_t *query,
    size_t query_size,
    glacier_model_support_result_v1_t *out_result,
    size_t out_result_size);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* GLACIER_MODEL_CONTRACT_H */
