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

int main(int argc, char **argv) {
    uint8_t artifact[GLACIER_ARTIFACT_MANIFEST_V1_SIZE];
    uint8_t plan[GLACIER_EXECUTION_PLAN_V1_SIZE];
    uint8_t result[GLACIER_RESULT_ENVELOPE_V1_SIZE];
    uint8_t result_root[GLACIER_MODEL_CONTRACT_ROOT_V1_SIZE];
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
    if (glacier_contract_abi_v1() != GLACIER_CONTRACT_ABI_V1) {
        fprintf(stderr, "unexpected contract ABI\n");
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

    puts("C consumer verified the experimental Model Contract V1 ABI");
    return 0;
}
