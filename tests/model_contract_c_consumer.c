#include "glacier/model_contract.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

static int hex_value(int character) {
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    character = tolower((unsigned char)character);
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    return -1;
}

static int read_hex_file(
    const char *path,
    uint8_t *output,
    size_t output_size
) {
    FILE *file = fopen(path, "rb");
    size_t written = 0;
    int high_nibble = -1;
    int character;
    int read_error;
    int close_error;

    if (file == NULL) {
        fprintf(stderr, "cannot open fixture: %s\n", path);
        return 0;
    }

    while ((character = fgetc(file)) != EOF) {
        int value;
        if (isspace((unsigned char)character)) {
            continue;
        }
        value = hex_value(character);
        if (value < 0 || written >= output_size) {
            fprintf(stderr, "invalid or oversized hex fixture: %s\n", path);
            fclose(file);
            return 0;
        }
        if (high_nibble < 0) {
            high_nibble = value;
        } else {
            output[written++] = (uint8_t)((high_nibble << 4) | value);
            high_nibble = -1;
        }
    }

    read_error = ferror(file);
    close_error = fclose(file);
    if (read_error || close_error != 0 || high_nibble >= 0 ||
        written != output_size) {
        fprintf(stderr, "fixture has the wrong encoded length: %s\n", path);
        return 0;
    }
    return 1;
}

static int all_zero(const uint8_t *bytes, size_t length) {
    size_t index;
    for (index = 0; index < length; ++index) {
        if (bytes[index] != 0) {
            return 0;
        }
    }
    return 1;
}

struct expected_support_profile {
    uint64_t index;
    uint64_t mask;
    uint64_t profile_abi;
    uint64_t lifecycle;
    uint64_t family;
    uint64_t operation;
    uint64_t input_kind;
    uint64_t output_kind;
    uint64_t max_batch_items;
    uint64_t max_input_features;
    uint64_t max_output_dimensions;
};

static const struct expected_support_profile expected_support_profiles[] = {
    {
        GLACIER_MODEL_SUPPORT_INDEX_VISION_ENCODER,
        GLACIER_MODEL_SUPPORT_MASK_VISION_ENCODER,
        GLACIER_MODEL_SUPPORT_PROFILE_VISION_ENCODER,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATELESS,
        GLACIER_MODEL_FAMILY_VISION_UNDERSTANDING,
        GLACIER_MODEL_OPERATION_ENCODE,
        GLACIER_MODEL_INPUT_IMAGE_FEATURE_U8,
        GLACIER_MODEL_OUTPUT_EMBEDDING_I32,
        UINT64_C(64),
        UINT64_C(65536),
        UINT64_C(16384),
    },
    {
        GLACIER_MODEL_SUPPORT_INDEX_AUDIO_WINDOW,
        GLACIER_MODEL_SUPPORT_MASK_AUDIO_WINDOW,
        GLACIER_MODEL_SUPPORT_PROFILE_AUDIO_WINDOW,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATELESS,
        GLACIER_MODEL_FAMILY_AUDIO_UNDERSTANDING,
        GLACIER_MODEL_OPERATION_ENCODE,
        GLACIER_MODEL_INPUT_AUDIO_FEATURE_I16,
        GLACIER_MODEL_OUTPUT_EMBEDDING_I32,
        UINT64_C(4096),
        UINT64_C(16384),
        UINT64_C(16384),
    },
    {
        GLACIER_MODEL_SUPPORT_INDEX_AUDIO_TRANSCRIPT,
        GLACIER_MODEL_SUPPORT_MASK_AUDIO_TRANSCRIPT,
        GLACIER_MODEL_SUPPORT_PROFILE_AUDIO_TRANSCRIPT,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATELESS,
        GLACIER_MODEL_FAMILY_AUDIO_UNDERSTANDING,
        GLACIER_MODEL_OPERATION_TRANSCRIBE,
        GLACIER_MODEL_INPUT_AUDIO_FEATURE_I16,
        GLACIER_MODEL_OUTPUT_TRANSCRIPT,
        UINT64_C(1),
        UINT64_C(4096),
        UINT64_C(384),
    },
    {
        GLACIER_MODEL_SUPPORT_INDEX_STATEFUL_TRANSCRIPT,
        GLACIER_MODEL_SUPPORT_MASK_STATEFUL_TRANSCRIPT,
        GLACIER_MODEL_SUPPORT_PROFILE_STATEFUL_TRANSCRIPT,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATEFUL,
        GLACIER_MODEL_FAMILY_AUDIO_UNDERSTANDING,
        GLACIER_MODEL_OPERATION_TRANSCRIBE,
        GLACIER_MODEL_INPUT_AUDIO_FEATURE_I16,
        GLACIER_MODEL_OUTPUT_TRANSCRIPT,
        UINT64_C(1),
        UINT64_C(4),
        UINT64_C(64),
    },
    {
        GLACIER_MODEL_SUPPORT_INDEX_TEMPORAL_VIDEO,
        GLACIER_MODEL_SUPPORT_MASK_TEMPORAL_VIDEO,
        GLACIER_MODEL_SUPPORT_PROFILE_TEMPORAL_VIDEO,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATELESS,
        GLACIER_MODEL_FAMILY_VIDEO_UNDERSTANDING,
        GLACIER_MODEL_OPERATION_ENCODE,
        GLACIER_MODEL_INPUT_VIDEO_FEATURE_U8,
        GLACIER_MODEL_OUTPUT_EMBEDDING_I32,
        UINT64_C(4096),
        UINT64_C(1048576),
        UINT64_C(16384),
    },
    {
        GLACIER_MODEL_SUPPORT_INDEX_VIDEO_SEGMENT,
        GLACIER_MODEL_SUPPORT_MASK_VIDEO_SEGMENT,
        GLACIER_MODEL_SUPPORT_PROFILE_VIDEO_SEGMENT,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATELESS,
        GLACIER_MODEL_FAMILY_VIDEO_UNDERSTANDING,
        GLACIER_MODEL_OPERATION_SEGMENT,
        GLACIER_MODEL_INPUT_VIDEO_FEATURE_U8,
        GLACIER_MODEL_OUTPUT_VIDEO_SEGMENT,
        UINT64_C(1),
        UINT64_C(1048576),
        UINT64_C(512),
    },
    {
        GLACIER_MODEL_SUPPORT_INDEX_STATEFUL_VIDEO,
        GLACIER_MODEL_SUPPORT_MASK_STATEFUL_VIDEO,
        GLACIER_MODEL_SUPPORT_PROFILE_STATEFUL_VIDEO,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATEFUL,
        GLACIER_MODEL_FAMILY_VIDEO_UNDERSTANDING,
        GLACIER_MODEL_OPERATION_SEGMENT,
        GLACIER_MODEL_INPUT_VIDEO_FEATURE_U8,
        GLACIER_MODEL_OUTPUT_VIDEO_SEGMENT,
        UINT64_C(1),
        UINT64_C(4),
        UINT64_C(512),
    },
    {
        GLACIER_MODEL_SUPPORT_INDEX_LATENT_STEP,
        GLACIER_MODEL_SUPPORT_MASK_LATENT_STEP,
        GLACIER_MODEL_SUPPORT_PROFILE_LATENT_STEP,
        GLACIER_MODEL_SUPPORT_LIFECYCLE_STATEFUL,
        GLACIER_MODEL_FAMILY_IMAGE_GENERATION,
        GLACIER_MODEL_OPERATION_DIFFUSE_STEP,
        GLACIER_MODEL_INPUT_LATENT_TENSOR,
        GLACIER_MODEL_OUTPUT_MEDIA_CHUNK,
        UINT64_C(1),
        UINT64_C(1048576),
        UINT64_C(1048576),
    },
};

int main(int argc, char **argv) {
    uint8_t artifact[GLACIER_ARTIFACT_MANIFEST_V1_SIZE];
    uint8_t plan[GLACIER_EXECUTION_PLAN_V1_SIZE];
    uint8_t result[GLACIER_RESULT_ENVELOPE_V1_SIZE];
    uint8_t result_root[GLACIER_MODEL_CONTRACT_ROOT_V1_SIZE];
    glacier_model_support_profile_v1_t support_profile;
    glacier_model_support_query_v1_t support_query;
    glacier_model_support_result_v1_t support_result;
    size_t support_index;
    uint32_t status;

    if (argc != 4) {
        fprintf(
            stderr,
            "usage: %s <artifact.hex> <plan.hex> <result.hex>\n",
            argv[0]
        );
        return 64;
    }
    if (!read_hex_file(argv[1], artifact, sizeof artifact) ||
        !read_hex_file(argv[2], plan, sizeof plan) ||
        !read_hex_file(argv[3], result, sizeof result)) {
        return 1;
    }
    if (glacier_contract_abi_v1() != GLACIER_CONTRACT_ABI_V1 ||
        glacier_model_support_registry_abi_v1() !=
            GLACIER_MODEL_SUPPORT_REGISTRY_ABI_V1) {
        fprintf(stderr, "unexpected contract ABI\n");
        return 1;
    }
    if (glacier_model_support_profile_count_v1() !=
        GLACIER_MODEL_SUPPORT_PROFILE_COUNT_V1) {
        fprintf(stderr, "unexpected model-support profile count\n");
        return 1;
    }

    for (support_index = 0;
         support_index <
         sizeof expected_support_profiles / sizeof expected_support_profiles[0];
         ++support_index) {
        const struct expected_support_profile *expected =
            &expected_support_profiles[support_index];

        memset(&support_profile, 0, sizeof support_profile);
        status = glacier_model_support_profile_get_v1(
            expected->index,
            &support_profile,
            sizeof support_profile
        );
        if (status != GLACIER_MODEL_CONTRACT_OK ||
            expected->index != support_index ||
            expected->mask != (UINT64_C(1) << expected->index) ||
            support_profile.profile_abi != expected->profile_abi ||
            support_profile.lifecycle != expected->lifecycle ||
            support_profile.evidence !=
                GLACIER_MODEL_SUPPORT_EVIDENCE_RETAINED_REFERENCE_FIXTURE ||
            support_profile.family != expected->family ||
            support_profile.operation != expected->operation ||
            support_profile.input_kind != expected->input_kind ||
            support_profile.output_kind != expected->output_kind ||
            support_profile.numerical_policy !=
                GLACIER_NUMERICAL_EXACT_INTEGER ||
            support_profile.max_batch_items != expected->max_batch_items ||
            support_profile.max_input_features !=
                expected->max_input_features ||
            support_profile.max_output_dimensions !=
                expected->max_output_dimensions ||
            support_profile.allowed_capabilities != UINT64_C(0)) {
            fprintf(
                stderr,
                "unexpected model-support profile at index %zu\n",
                support_index
            );
            return 1;
        }
    }

    memset(&support_profile, 0xa5, sizeof support_profile);
    status = glacier_model_support_profile_get_v1(
        GLACIER_MODEL_SUPPORT_PROFILE_COUNT_V1,
        &support_profile,
        sizeof support_profile
    );
    if (status != GLACIER_MODEL_CONTRACT_OUT_OF_RANGE ||
        !all_zero(
            (const uint8_t *)&support_profile,
            sizeof support_profile
        )) {
        fprintf(stderr, "out-of-range support profile did not fail closed\n");
        return 1;
    }

    memset(&support_query, 0, sizeof support_query);
    support_query.family = GLACIER_MODEL_FAMILY_AUDIO_UNDERSTANDING;
    support_query.operation = GLACIER_MODEL_OPERATION_TRANSCRIBE;
    support_query.input_kind = GLACIER_MODEL_INPUT_AUDIO_FEATURE_I16;
    support_query.output_kind = GLACIER_MODEL_OUTPUT_TRANSCRIPT;
    support_query.numerical_policy = GLACIER_NUMERICAL_EXACT_INTEGER;
    support_query.batch_items = UINT64_C(1);
    support_query.input_features = UINT64_C(4);
    support_query.output_dimensions = UINT64_C(64);
    memset(&support_result, 0, sizeof support_result);
    status = glacier_model_support_query_v1(
        &support_query,
        sizeof support_query,
        &support_result,
        sizeof support_result
    );
    if (status != GLACIER_MODEL_CONTRACT_OK ||
        support_result.compatible != UINT64_C(1) ||
        support_result.unsupported_reason !=
            GLACIER_MODEL_SUPPORT_UNSUPPORTED_NONE ||
        support_result.matching_profile_mask !=
            (GLACIER_MODEL_SUPPORT_MASK_AUDIO_TRANSCRIPT |
             GLACIER_MODEL_SUPPORT_MASK_STATEFUL_TRANSCRIPT)) {
        fprintf(stderr, "model-support query did not return both profiles\n");
        return 1;
    }

    support_query.required_capabilities = UINT64_C(1);
    status = glacier_model_support_query_v1(
        &support_query,
        sizeof support_query,
        &support_result,
        sizeof support_result
    );
    if (status != GLACIER_MODEL_CONTRACT_OK ||
        support_result.compatible != UINT64_C(0) ||
        support_result.unsupported_reason !=
            GLACIER_MODEL_SUPPORT_UNSUPPORTED_CAPABILITIES ||
        support_result.matching_profile_mask != UINT64_C(0)) {
        fprintf(stderr, "unsupported capability was not explicit\n");
        return 1;
    }

    memset(result_root, 0xa5, sizeof result_root);
    status = glacier_model_contract_verify_v1(
        artifact,
        sizeof artifact,
        plan,
        sizeof plan,
        result,
        sizeof result,
        result_root
    );
    if (status != GLACIER_MODEL_CONTRACT_OK ||
        memcmp(
            result_root,
            result + sizeof result - sizeof result_root,
            sizeof result_root
        ) != 0) {
        fprintf(stderr, "valid contract chain failed with status %u\n", status);
        return 1;
    }

    status = glacier_model_contract_verify_v1(
        artifact,
        sizeof artifact,
        plan,
        sizeof plan,
        result,
        sizeof result,
        result + sizeof result - GLACIER_MODEL_CONTRACT_ROOT_V1_SIZE
    );
    if (status != GLACIER_MODEL_CONTRACT_OK) {
        fprintf(stderr, "zero-copy result-root check failed: %u\n", status);
        return 1;
    }

    artifact[0] ^= UINT8_C(1);
    memset(result_root, 0xa5, sizeof result_root);
    status = glacier_model_contract_verify_v1(
        artifact,
        sizeof artifact,
        plan,
        sizeof plan,
        result,
        sizeof result,
        result_root
    );
    if (status != GLACIER_MODEL_CONTRACT_INVALID_ARTIFACT ||
        !all_zero(result_root, sizeof result_root)) {
        fprintf(stderr, "mutated artifact did not fail closed: %u\n", status);
        return 1;
    }

    puts(
        "C consumer verified the experimental Model Contract V1 "
        "and support registry ABI"
    );
    return 0;
}
