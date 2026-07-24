#ifndef GLACIER_MODEL_CONTRACT_H
#define GLACIER_MODEL_CONTRACT_H

/*
 * EXPERIMENTAL: This allocation-free C ABI may change before it is declared
 * stable. It verifies canonical Model Contract V1 wires; it does not expose
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

#define GLACIER_ARTIFACT_MANIFEST_V1_SIZE ((size_t)320)
#define GLACIER_EXECUTION_PLAN_V1_SIZE ((size_t)768)
#define GLACIER_RESULT_ENVELOPE_V1_SIZE ((size_t)768)
#define GLACIER_MODEL_CONTRACT_ROOT_V1_SIZE ((size_t)32)

#define GLACIER_MODEL_CONTRACT_OK UINT32_C(0)
#define GLACIER_MODEL_CONTRACT_NULL_ARGUMENT UINT32_C(1)
#define GLACIER_MODEL_CONTRACT_INVALID_SIZE UINT32_C(2)
#define GLACIER_MODEL_CONTRACT_INVALID_ARTIFACT UINT32_C(3)
#define GLACIER_MODEL_CONTRACT_INVALID_PLAN UINT32_C(4)
#define GLACIER_MODEL_CONTRACT_INVALID_RESULT UINT32_C(5)
#define GLACIER_MODEL_CONTRACT_BINDING_MISMATCH UINT32_C(6)

#ifdef __cplusplus
extern "C" {
#endif

GLACIER_MODEL_CONTRACT_API uint64_t glacier_contract_abi_v1(void);

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

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* GLACIER_MODEL_CONTRACT_H */
