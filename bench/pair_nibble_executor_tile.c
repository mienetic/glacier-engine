#include <stdatomic.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OUT_FEATURES 4864u
#define IN_FEATURES 896u
#define MAX_PARTICIPANTS 8u
#define CAMPAIGN_RUNS 3u
#define BALANCED_ROUNDS 2u
#define SAMPLES_PER_ROUND 101u
#define WARMUP_CYCLES 20u

void glacier_pair_nibble_matvec_neon_q8_prequant_f16scale_rows4_k16(
    const int8_t *, const float *, const uint8_t *, const __fp16 *,
    const float *, const float *, float *, float *, size_t, size_t, size_t);

typedef struct TileProbe {
    pthread_mutex_t mutex;
    pthread_cond_t work;
    pthread_cond_t done;
    pthread_t workers[MAX_PARTICIPANTS - 1];
    size_t participants;
    size_t generation;
    size_t completed;
    int stopping;
    _Atomic size_t next_shard;
    _Atomic unsigned int worker_qos_failures;
    size_t tile_rows;
    size_t group_size;
    int8_t *q_input;
    float *activation_scales;
    uint8_t *paired_weights;
    __fp16 *paired_scales;
    float *gate_bias;
    float *up_bias;
    float *gate_output;
    float *up_output;
} TileProbe;

static volatile uint32_t output_sink;
static mach_timebase_info_data_t timebase;

static void *aligned_alloc64(size_t bytes)
{
    void *result = NULL;
    if (posix_memalign(&result, 64, bytes) != 0 || result == NULL) {
        fprintf(stderr, "allocation failed for %zu bytes\n", bytes);
        exit(2);
    }
    return result;
}

static void run_claims(TileProbe *probe)
{
    const size_t scales_per_row = 2 * IN_FEATURES / probe->group_size;
    for (;;) {
        const size_t shard = atomic_fetch_add_explicit(
            &probe->next_shard, 1, memory_order_relaxed);
        const size_t row_start = shard * probe->tile_rows;
        if (row_start >= OUT_FEATURES) return;
        size_t row_end = row_start + probe->tile_rows;
        if (row_end > OUT_FEATURES) row_end = OUT_FEATURES;
        glacier_pair_nibble_matvec_neon_q8_prequant_f16scale_rows4_k16(
            probe->q_input,
            probe->activation_scales,
            probe->paired_weights + row_start * IN_FEATURES,
            probe->paired_scales + row_start * scales_per_row,
            probe->gate_bias + row_start,
            probe->up_bias + row_start,
            probe->gate_output + row_start,
            probe->up_output + row_start,
            row_end - row_start,
            IN_FEATURES,
            probe->group_size);
    }
}

static void *worker_main(void *opaque)
{
    TileProbe *probe = opaque;
    if (pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) != 0) {
        atomic_fetch_add_explicit(
            &probe->worker_qos_failures, 1, memory_order_relaxed);
    }
    size_t seen_generation = 0;
    for (;;) {
        pthread_mutex_lock(&probe->mutex);
        while (probe->generation == seen_generation && !probe->stopping) {
            pthread_cond_wait(&probe->work, &probe->mutex);
        }
        if (probe->stopping) {
            pthread_mutex_unlock(&probe->mutex);
            return NULL;
        }
        seen_generation = probe->generation;
        pthread_mutex_unlock(&probe->mutex);

        run_claims(probe);

        pthread_mutex_lock(&probe->mutex);
        ++probe->completed;
        if (probe->completed == probe->participants - 1) {
            pthread_cond_signal(&probe->done);
        }
        pthread_mutex_unlock(&probe->mutex);
    }
}

static void dispatch(TileProbe *probe, size_t tile_rows)
{
    pthread_mutex_lock(&probe->mutex);
    probe->tile_rows = tile_rows;
    probe->completed = 0;
    atomic_store_explicit(&probe->next_shard, 0, memory_order_relaxed);
    ++probe->generation;
    pthread_cond_broadcast(&probe->work);
    pthread_mutex_unlock(&probe->mutex);

    run_claims(probe);

    pthread_mutex_lock(&probe->mutex);
    while (probe->completed != probe->participants - 1) {
        pthread_cond_wait(&probe->done, &probe->mutex);
    }
    pthread_mutex_unlock(&probe->mutex);
}

static double dispatch_ns(TileProbe *probe, size_t tile_rows)
{
    const uint64_t before = mach_continuous_time();
    dispatch(probe, tile_rows);
    const uint64_t after = mach_continuous_time();
    uint32_t bits;
    memcpy(&bits, probe->gate_output + (after % OUT_FEATURES), sizeof(bits));
    output_sink ^= bits;
    return (double)(after - before) *
        (double)timebase.numer / (double)timebase.denom;
}

static void initialize_probe(
    TileProbe *probe,
    size_t group_size,
    size_t participants)
{
    memset(probe, 0, sizeof(*probe));
    probe->group_size = group_size;
    probe->participants = participants;
    pthread_mutex_init(&probe->mutex, NULL);
    pthread_cond_init(&probe->work, NULL);
    pthread_cond_init(&probe->done, NULL);

    const size_t coefficients = OUT_FEATURES * IN_FEATURES;
    const size_t activation_count =
        group_size == 8 ? IN_FEATURES / 32 : IN_FEATURES / 16;
    const size_t paired_scale_count = 2 * coefficients / group_size;
    probe->q_input = aligned_alloc64(IN_FEATURES);
    probe->activation_scales = aligned_alloc64(
        activation_count * sizeof(float));
    probe->paired_weights = aligned_alloc64(coefficients);
    probe->paired_scales = aligned_alloc64(
        paired_scale_count * sizeof(__fp16));
    probe->gate_bias = aligned_alloc64(OUT_FEATURES * sizeof(float));
    probe->up_bias = aligned_alloc64(OUT_FEATURES * sizeof(float));
    probe->gate_output = aligned_alloc64(OUT_FEATURES * sizeof(float));
    probe->up_output = aligned_alloc64(OUT_FEATURES * sizeof(float));

    for (size_t index = 0; index < IN_FEATURES; ++index) {
        probe->q_input[index] = (int8_t)((index * 17) % 127);
    }
    for (size_t index = 0; index < activation_count; ++index) {
        probe->activation_scales[index] =
            0.003f + (float)(index % 13) * 0.0001f;
    }
    for (size_t index = 0; index < coefficients; ++index) {
        probe->paired_weights[index] = (uint8_t)(
            ((index * 7) & 15) | (((index * 11) & 15) << 4));
    }
    for (size_t index = 0; index < paired_scale_count; ++index) {
        probe->paired_scales[index] =
            (__fp16)(0.002f + (float)(index % 17) * 0.0001f);
    }
    for (size_t index = 0; index < OUT_FEATURES; ++index) {
        probe->gate_bias[index] = (float)(index % 19) * 0.001f;
        probe->up_bias[index] = (float)(index % 23) * -0.001f;
    }

    for (size_t index = 0; index < participants - 1; ++index) {
        if (pthread_create(
                &probe->workers[index], NULL, worker_main, probe) != 0) {
            fprintf(stderr, "pthread_create failed\n");
            exit(2);
        }
    }
}

static void destroy_probe(TileProbe *probe)
{
    pthread_mutex_lock(&probe->mutex);
    probe->stopping = 1;
    pthread_cond_broadcast(&probe->work);
    pthread_mutex_unlock(&probe->mutex);
    for (size_t index = 0; index < probe->participants - 1; ++index) {
        pthread_join(probe->workers[index], NULL);
    }
    free(probe->q_input);
    free(probe->activation_scales);
    free(probe->paired_weights);
    free(probe->paired_scales);
    free(probe->gate_bias);
    free(probe->up_bias);
    free(probe->gate_output);
    free(probe->up_output);
    pthread_cond_destroy(&probe->done);
    pthread_cond_destroy(&probe->work);
    pthread_mutex_destroy(&probe->mutex);
}

static int verify_tiles(
    TileProbe *probe,
    FILE *verification,
    uint64_t campaign_id,
    size_t run_index)
{
    const size_t tiles[5] = {16, 32, 64, 128, 256};
    float *gate_reference = aligned_alloc64(OUT_FEATURES * sizeof(float));
    float *up_reference = aligned_alloc64(OUT_FEATURES * sizeof(float));
    dispatch(probe, tiles[0]);
    memcpy(gate_reference, probe->gate_output, OUT_FEATURES * sizeof(float));
    memcpy(up_reference, probe->up_output, OUT_FEATURES * sizeof(float));
    for (size_t index = 1; index < 5; ++index) {
        dispatch(probe, tiles[index]);
        if (memcmp(
                gate_reference,
                probe->gate_output,
                OUT_FEATURES * sizeof(float)) != 0 ||
            memcmp(
                up_reference,
                probe->up_output,
                OUT_FEATURES * sizeof(float)) != 0) {
            fprintf(
                verification,
                "VERIFY_FAIL,run_id=%" PRIu64 ",run=%zu,t%zu,g%zu,tile=%zu\n",
                campaign_id,
                run_index,
                probe->participants,
                probe->group_size,
                tiles[index]);
            free(gate_reference);
            free(up_reference);
            return 0;
        }
    }
    fprintf(
        verification,
        "VERIFY_PASS,run_id=%" PRIu64 ",run=%zu,t%zu,g%zu,"
        "tile16_32_64_128_256,bit_exact\n",
        campaign_id,
        run_index,
        probe->participants,
        probe->group_size);
    fflush(verification);
    free(gate_reference);
    free(up_reference);
    return 1;
}

static int run_group(
    FILE *raw,
    FILE *verification,
    uint64_t campaign_id,
    size_t group_size,
    size_t participants)
{
    TileProbe probe;
    initialize_probe(&probe, group_size, participants);
    const size_t tiles[5] = {16, 32, 64, 128, 256};
    for (size_t run_index = 0; run_index < CAMPAIGN_RUNS; ++run_index) {
        if (!verify_tiles(&probe, verification, campaign_id, run_index)) {
            destroy_probe(&probe);
            return 0;
        }
        for (size_t round = 0; round < BALANCED_ROUNDS; ++round) {
            const int reverse = round != 0;
            for (size_t warmup = 0; warmup < WARMUP_CYCLES; ++warmup) {
                for (size_t position = 0; position < 5; ++position) {
                    const size_t tile_index = reverse ? 4 - position : position;
                    dispatch(&probe, tiles[tile_index]);
                }
            }
            for (size_t sample = 0; sample < SAMPLES_PER_ROUND; ++sample) {
                for (size_t position = 0; position < 5; ++position) {
                    const size_t tile_index = reverse ? 4 - position : position;
                    const size_t tile_rows = tiles[tile_index];
                    const double elapsed_ns = dispatch_ns(&probe, tile_rows);
                    fprintf(
                        raw,
                        "%" PRIu64 ",%zu,%zu,%zu,%zu,%zu,%zu,%zu,%zu,%.3f\n",
                        campaign_id,
                        run_index,
                        participants,
                        group_size,
                        tile_rows,
                        (OUT_FEATURES + tile_rows - 1) / tile_rows,
                        round,
                        sample,
                        position,
                        elapsed_ns);
                }
            }
            fflush(raw);
        }
    }
    const unsigned int qos_failures = atomic_load_explicit(
        &probe.worker_qos_failures, memory_order_relaxed);
    fprintf(
        verification,
        "WORKER_QOS,g%zu,participants=%zu,failures=%u\n",
        group_size,
        participants,
        qos_failures);
    destroy_probe(&probe);
    return qos_failures == 0;
}

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s RAW_CSV VERIFY_LOG\n", argv[0]);
        return 2;
    }
    FILE *raw = fopen(argv[1], "w");
    FILE *verification = fopen(argv[2], "w");
    if (raw == NULL || verification == NULL) {
        perror("fopen");
        if (raw != NULL) fclose(raw);
        if (verification != NULL) fclose(verification);
        return 2;
    }
    mach_timebase_info(&timebase);
    const uint64_t campaign_id = mach_continuous_time();
    const int main_qos_status =
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    fprintf(
        verification,
        "CAMPAIGN,run_id=%" PRIu64 ",out=%u,in=%u,participants=1_2_4_8,"
        "runs=%u,rounds=%u,samples=%u,warmups=%u\n",
        campaign_id,
        OUT_FEATURES,
        IN_FEATURES,
        CAMPAIGN_RUNS,
        BALANCED_ROUNDS,
        SAMPLES_PER_ROUND,
        WARMUP_CYCLES);
    fprintf(verification, "MAIN_QOS,status=%d\n", main_qos_status);
    fprintf(
        raw,
        "run_id,run_index,participants,group_size,tile_rows,claims,round,sample,"
        "position,elapsed_ns\n");

    int valid = main_qos_status == 0;
    const size_t participant_counts[4] = {1, 2, 4, 8};
    for (size_t index = 0; valid && index < 4; ++index) {
        valid = run_group(
            raw,
            verification,
            campaign_id,
            8,
            participant_counts[index]) &&
            run_group(
                raw,
                verification,
                campaign_id,
                16,
                participant_counts[index]);
    }
    fprintf(verification, "SINK,value=%u\n", output_sink);
    fprintf(verification, "CAMPAIGN_%s\n", valid ? "PASS" : "FAIL");
    fclose(raw);
    fclose(verification);
    return valid ? 0 : 1;
}
