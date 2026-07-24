#include "glacier/model_contract.h"

static_assert(GLACIER_ARTIFACT_MANIFEST_V1_SIZE == 320);
static_assert(GLACIER_EXECUTION_PLAN_V1_SIZE == 768);
static_assert(GLACIER_RESULT_ENVELOPE_V1_SIZE == 768);
static_assert(GLACIER_MODEL_CONTRACT_ROOT_V1_SIZE == 32);

int main() {
    return glacier_contract_abi_v1() == GLACIER_CONTRACT_ABI_V1 ? 0 : 1;
}
