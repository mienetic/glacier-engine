#include "glacier/model_contract.h"

static_assert(GLACIER_ARTIFACT_MANIFEST_V1_SIZE == 320);
static_assert(GLACIER_EXECUTION_PLAN_V1_SIZE == 768);
static_assert(GLACIER_RESULT_ENVELOPE_V1_SIZE == 768);
static_assert(GLACIER_MODEL_CONTRACT_ROOT_V1_SIZE == 32);
static_assert(sizeof(glacier_model_support_profile_v1_t) == 96);
static_assert(sizeof(glacier_model_support_query_v1_t) == 72);
static_assert(sizeof(glacier_model_support_result_v1_t) == 24);
static_assert(GLACIER_MODEL_SUPPORT_PROFILE_COUNT_V1 == 8);

int main() {
    return glacier_contract_abi_v1() == GLACIER_CONTRACT_ABI_V1 &&
                   glacier_model_support_registry_abi_v1() ==
                       GLACIER_MODEL_SUPPORT_REGISTRY_ABI_V1 &&
                   glacier_model_support_profile_count_v1() ==
                       GLACIER_MODEL_SUPPORT_PROFILE_COUNT_V1
               ? 0
               : 1;
}
