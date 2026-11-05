/*
TEST ADAPTER COPY - a guided copy of train_adapter.cu

Start here
----------
This file runs GPT-2 with a small trainable side path inside each transformer
block. That side path is the adapter. It gives the model extra weights to adjust
for a task while the much larger base model can stay frozen.

A token is one item of text, often a word piece. GPT-2 turns each token into a
list of numbers called a feature vector. A transformer block updates those
numbers using the preceding text. Stacking blocks gives the model more chances
to build useful features before predicting the next token.

Where the adapter fits
----------------------
The supplied diagram gets the branching right. Both paths start from LN1(x),
not from each other. The attention label includes its final output projection.
The adapter doesn't replace attention and doesn't read its output.

    z       = LN1(x)
    a       = Attention(z)
    h       = GELU(z * down_w^T + down_b)
    delta   = h * up_w^T + up_b
    y       = x + a + delta
    output  = y + MLP(LN2(y))

Here x is the block input. LN1 rescales features within each token and applies
learned scale and bias. Attention mixes information from tokens using a causal
mask, so a prediction cannot look ahead at later tokens.

The adapter takes a narrower route. Down projection mixes C features into r
features with a learned matrix and bias. GELU smoothly scales those values,
keeping the two projections from collapsing into one linear transformation.
Up projection mixes the r values back into C values. The output can now be
added to attention's C-wide result. The x shortcut keeps the original signal
in the sum; this is the residual connection.

The next part of the supplied diagram is LN2, then GPT-2's feed-forward network
(MLP), then another residual sum. That MLP expands C to 4*C and contracts back
to C. It's a different path from the small adapter described above.

The same forward flow as a Mermaid diagram:
    flowchart LR
        X[Block input x] --> LN[First layer normalization]
        LN --> ATT[Causal attention and output projection]
        LN --> DOWN[Down projection and bias]
        DOWN --> GELU[GELU]
        GELU --> UP[Up projection and bias]
        ATT --> SUM[Add all three paths]
        UP --> SUM
        X --> SUM
        SUM --> LN2[Second layer normalization]
        LN2 --> MLP[Feed-forward network]
        MLP --> SUM2[Add]
        SUM --> SUM2
        SUM2 --> NEXT[Next block or final prediction]

Sizes without the mystery
-------------------------
B = sequences processed together; T = tokens in each sequence.
C = features per token; r = the adapter's smaller hidden width.
L = transformer blocks; V = real vocabulary size; Vp = padded vocabulary size.
A tensor is just a numbered array with a shape, such as [B,T,C].

    input and output     [B,T,C]
    hidden adapter state [B,T,r]
    down_w / down_b      [r,C] / [r] in each block
    up_w / up_b          [C,r] / [C] in each block

For the 12-block GPT-2 here, C=768 and r=32. Each block adds
2*C*r + r + C weights and biases, giving 599,424 adapter parameters in total.
The base model has about 124 million parameters, so this is a much smaller set.
The down weights start as small random numbers. Up weights and both biases
start at zero, making delta zero at initialization. So the new adapter starts
by leaving the base forward result alone.

How learning and validation fit
-------------------------------
A forward pass produces logits: scores for possible next tokens. Cross-entropy
loss checks how much probability the model assigned to the actual next token.
For one token the loss is -log(p_correct); this file averages it over tokens.
Loss uses natural logs (nats). Lower is better. It is not a count of mistakes.

Backward propagation follows the chain rule to work out how changing a weight
would change loss. Those derivatives are gradients. AdamW uses their history
to choose weight updates. Freezing the base means skipping its weight updates;
gradients still need to pass through its layers to reach earlier adapters.

Validation measures held-out text without changing weights. The reports say
which completed step was measured and keep the raw cross-entropy value.
"Loss relative to first validation" means 100 * current_loss / first_loss.
It starts at 100%; 80% means one fifth less loss than that reference.
It is NOT token error percentage or prediction accuracy. Values above 100%
mean loss got worse. Training has a separate first-training-loss reference.
Each reference starts fresh in this process, including after a resumed run.
Zero or invalid reference losses produce n/a instead of a made-up percentage.
Step 0 validation happens before updates; step 5 validation follows five loop
iterations. An outlier rule can skip an update within one of those iterations.

Reading the rest
----------------
The order is: includes -> array layouts -> memory -> forward pass -> loss ->
backward pass -> optimizer -> files -> command-line setup -> training loop.
Comments describe what an instruction does and how it does it. Temporary GPU
buffers are called scratch space; they hold working values rather than files.

Known inherited issues
----------------------
This copy changes comments and reporting, not the training mathematics.
The adapter optimizer still reuses state between tensors. Its backward path
still overwrites live gradient buffers and combines gradients at the wrong
projection boundary. Local notes mark those spots below. A successful build or
forward check does not establish correct adapter training. Keep those limits
in mind when reading the intended architecture above.

Comment style reference: conversational rhythm, short phrases, little filler.
https://www.writersdigest.com/on-writing-lifelike-dialogue
*/

// System headers handle files, paths and ordinary CPU-side support.
// The llmc headers below supply token loading, math kernels and training utilities.
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string>
#include <string_view>
#include <sys/stat.h>
#include <sys/types.h>

#include "llmc/utils.h"

#include "llmc/tokenizer.h"

#include "llmc/dataloader.h"

#include "llmc/rand.h"

#include "llmc/schedulers.h"

#include "llmc/sampler.h"

#include "llmc/logger.h"

#include "llmc/mfu.h"

#include "llmc/outlier_detector.h"

// CUDA launches work on the GPU; cuBLAS supplies optimized matrix multiplication.
// A CUDA stream keeps dependent GPU operations in the requested order.
#include "llmc/cuda_common.h"

#include "llmc/cuda_utils.cuh"

#include "llmc/cublas_common.h"

#include "llmc/encoder.cuh"

#include "llmc/layernorm.cuh"

#include "llmc/matmul.cuh"
#ifdef ENABLE_CUDNN

#include "llmc/cudnn_att.h"
#else

#include "llmc/attention.cuh"
#endif

#include "llmc/fused_classifier.cuh"

#include "llmc/adamw.cuh"

#include "llmc/global_norm.cuh"

#include "llmc/zero.cuh"

// Build checkpoint paths in this reusable character array.
char filename_buffer[512];

// Keep the GPU hardware properties here after CUDA initialization.
cudaDeviceProp deviceProp;
cudaStream_t main_stream;

constexpr const size_t IO_BUF_SIZE = 32 * 1024 * 1024;

typedef struct
{
    int max_seq_len;
    int vocab_size;
    int padded_vocab_size;
    int num_layers;
    int num_heads;
    int channels;
} GPT2Config;

// Group the base weights into 16 named arrays; L copies live inside block arrays.
constexpr const int NUM_PARAMETER_TENSORS = 16;
typedef struct
{
    floatX *wte;
    floatX *wpe;
    floatX *ln1w;
    floatX *ln1b;
    floatX *qkvw;
    floatX *qkvb;
    floatX *attprojw;
    floatX *attprojb;
    floatX *ln2w;
    floatX *ln2b;
    floatX *fcw;
    floatX *fcb;
    floatX *fcprojw;
    floatX *fcprojb;
    floatX *lnfw;
    floatX *lnfb;
} ParameterTensors;
static_assert(sizeof(ParameterTensors) == NUM_PARAMETER_TENSORS * sizeof(void *), "Inconsistent sizes!");

// Count the elements in each base-model array.
// These sizes tell the allocator how much GPU memory each weight group needs.
void fill_in_parameter_sizes(size_t *param_sizes, size_t *param_sizeof, GPT2Config config)
{
    // Pad vocabulary storage for GPU-friendly alignment; padding is not extra real tokens.
    size_t Vp = config.padded_vocab_size;
    size_t C = config.channels;
    size_t maxT = config.max_seq_len;
    size_t L = config.num_layers;
    param_sizes[0] = Vp * C;
    param_sizes[1] = maxT * C;
    param_sizes[2] = L * C;
    param_sizes[3] = L * C;
    // QKV projects C features into three C-wide arrays: queries, keys and values.
    param_sizes[4] = L * (3 * C) * C;
    param_sizes[5] = L * (3 * C);
    param_sizes[6] = L * C * C;
    param_sizes[7] = L * C;
    param_sizes[8] = L * C;
    param_sizes[9] = L * C;
    // The ordinary feed-forward network expands features to four times the model width.
    param_sizes[10] = L * (4 * C) * C;
    param_sizes[11] = L * (4 * C);
    // The second feed-forward projection brings those expanded features back to C.
    param_sizes[12] = L * C * (4 * C);
    param_sizes[13] = L * C;
    param_sizes[14] = C;
    param_sizes[15] = C;

    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++)
    {
        param_sizeof[i] = sizeof(floatX);
    }
}

// Reserve one GPU allocation for base weights, then give each array its slice.
// A pointer marks where that slice starts; it does not copy the numbers.
void *malloc_and_point_parameters(ParameterTensors *params, size_t *param_elements, size_t *param_sizeof)
{

    size_t num_parameters_bytes = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++)
    {
        num_parameters_bytes += param_elements[i] * param_sizeof[i];
    }

    void *params_memory;
    cudaCheck(cudaMalloc((void **)&params_memory, num_parameters_bytes));

    floatX **ptrs[] = {
        &params->wte, &params->wpe, &params->ln1w, &params->ln1b, &params->qkvw, &params->qkvb,
        &params->attprojw, &params->attprojb, &params->ln2w, &params->ln2b, &params->fcw, &params->fcb,
        &params->fcprojw, &params->fcprojb, &params->lnfw, &params->lnfb};
    char *params_memory_iterator = (char *)params_memory;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++)
    {
        *(ptrs[i]) = (floatX *)params_memory_iterator;
        params_memory_iterator += param_elements[i] * param_sizeof[i];
    }
    return params_memory;
}

// Track 21 groups of intermediate values needed by the GPU passes.
constexpr int NUM_ACTIVATION_TENSORS = 21;
typedef struct
{
    floatX *encoded;
    floatX *ln1;
    float *ln1_mean;
    float *ln1_rstd;
    floatX *atty;

#if ENABLE_CUDNN
    float *att;
#else
    floatX *att;
#endif

    floatX *residual2;
    floatX *ln2;
    float *ln2_mean;
    float *ln2_rstd;
    floatX *fch;
    floatX *fch_gelu;
    floatX *residual3;
    floatX *lnf;
    float *lnf_mean;
    float *lnf_rstd;
    float *losses;

    floatX *qkvr;

    floatX *output;

    floatX *scratch_bt4c;
    floatX *scratch_btc;
} ActivationTensors;

struct TensorSpec
{
    void **ptr;
    size_t size;
    DType type;
};

#define TENSOR_SPEC(pointer, size) TensorSpec{(void **)(&pointer), (size), dtype_of(pointer)};

// Plan space for the intermediate forward values, called activations.
// Recomputation saves memory by rebuilding selected values during backward.
void fill_in_activation_sizes(const ActivationTensors *data, TensorSpec (&tensors)[NUM_ACTIVATION_TENSORS], size_t B, size_t T, GPT2Config config, int recompute)
{
    // Pad vocabulary storage for GPU-friendly alignment; padding is not extra real tokens.
    size_t Vp = config.padded_vocab_size;
    size_t L = config.num_layers;
    size_t NH = config.num_heads;
    size_t C = config.channels;
    tensors[0] = TENSOR_SPEC(data->encoded, B * T * C);

    tensors[1] = TENSOR_SPEC(data->ln1, (recompute < 2) ? L * B * T * C : 0);
    tensors[2] = TENSOR_SPEC(data->ln1_mean, L * B * T);
    tensors[3] = TENSOR_SPEC(data->ln1_rstd, L * B * T);
    tensors[4] = TENSOR_SPEC(data->atty, L * B * T * C);
#ifdef ENABLE_CUDNN

    tensors[5] = TENSOR_SPEC(data->att, L * B * NH * T);
#else
    tensors[5] = TENSOR_SPEC(data->att, L * B * NH * T * T);
#endif
    tensors[6] = TENSOR_SPEC(data->residual2, L * B * T * C);

    tensors[7] = TENSOR_SPEC(data->ln2, (recompute < 2) ? L * B * T * C : 0);
    tensors[8] = TENSOR_SPEC(data->ln2_mean, L * B * T);
    tensors[9] = TENSOR_SPEC(data->ln2_rstd, L * B * T);
    tensors[10] = TENSOR_SPEC(data->fch, L * B * T * 4 * C);

    tensors[11] = TENSOR_SPEC(data->fch_gelu, (recompute < 1) ? L * B * T * 4 * C : B * T * 4 * C);
    tensors[12] = TENSOR_SPEC(data->residual3, L * B * T * C);
    tensors[13] = TENSOR_SPEC(data->lnf, B * T * C);
    tensors[14] = TENSOR_SPEC(data->lnf_mean, B * T);
    tensors[15] = TENSOR_SPEC(data->lnf_rstd, B * T);
    tensors[16] = TENSOR_SPEC(data->losses, B * T);
    tensors[17] = TENSOR_SPEC(data->qkvr, L * B * T * 3 * C);
    tensors[18] = TENSOR_SPEC(data->output, B * T * max(3 * C, max(NH * T, Vp)));

    tensors[19] = TENSOR_SPEC(data->scratch_bt4c, B * T * 4 * C);
    tensors[20] = TENSOR_SPEC(data->scratch_btc, B * T * C);
}

// Reserve activation memory and connect the planned arrays to it.
// Shared scratch arrays reuse space when earlier values are no longer needed.
void *malloc_and_point_activations(TensorSpec (&tensors)[NUM_ACTIVATION_TENSORS])
{
    size_t bytes = 0;
    for (size_t i = 0; i < NUM_ACTIVATION_TENSORS; i++)
    {
        bytes += tensors[i].size * sizeof_dtype(tensors[i].type);
    }

    printf0("allocating %d MiB for activations\n", (int)round(bytes / (1024 * 1024)));

    void *acts_memory;
    cudaCheck(cudaMalloc((void **)&acts_memory, bytes));

    cudaCheck(cudaMemset(acts_memory, 0, bytes));

    char *acts_memory_iterator = (char *)acts_memory;
    for (size_t i = 0; i < NUM_ACTIVATION_TENSORS; i++)
    {

        if (tensors[i].size == 0)
        {
            *(tensors[i].ptr) = NULL;
        }
        else
        {
            *(tensors[i].ptr) = acts_memory_iterator;
            acts_memory_iterator += tensors[i].size * sizeof_dtype(tensors[i].type);
        }
    }
    return acts_memory;
}

typedef struct
{
    // These weights mix the full feature vector into the smaller adapter width.
    floatX *down_w;
    // This bias adds one learned offset for each hidden adapter feature.
    floatX *down_b;
    // These weights mix hidden adapter features back into the model width.
    floatX *up_w;
    // This bias adds one learned offset for each output feature.
    floatX *up_b;
} AdapterParams;

typedef struct
{
    // Hold the GELU output so the up projection and backward pass can read it.
    floatX *h;
} AdapterActs;

// Gradients have the same shapes as adapter parameters, but hold loss derivatives.
typedef struct
{
    // Track how changing each down weight would change the loss.
    floatX *down_w;
    // Track the loss derivative for each hidden-feature bias.
    floatX *down_b;
    // Track how changing each up weight would change the loss.
    floatX *up_w;
    // Track the loss derivative for each output-feature bias.
    floatX *up_b;
} AdapterGrads;

typedef struct
{
    // Record the layer count, feature width and vocabulary sizes for this model.
    GPT2Config config;

    // Store pointers to learned base weights; the numbers themselves live on the GPU.
    ParameterTensors params;
    size_t param_elements[NUM_PARAMETER_TENSORS];
    size_t param_sizeof[NUM_PARAMETER_TENSORS];
    void *params_memory;
    size_t num_parameters;
    size_t num_parameters_bytes;

    // Store base-weight derivatives separately so a measurement cannot overwrite a weight.
    ParameterTensors grads;
    void *grads_memory;

    // AdamW keeps a running average of gradients here, giving updates some momentum.
    float *m_memory;
    // AdamW tracks squared gradients here to adjust the scale of each parameter update.
    float *v_memory;
    // Optional FP32 master values reduce rounding loss when working weights use fewer bits.
    float *master_weights;

    // Keep the intermediate feature values needed for later layers and backward calculations.
    ActivationTensors acts;
    TensorSpec acts_specs[NUM_ACTIVATION_TENSORS];
    void *acts_memory;

    int batch_size;
    int seq_len;
    int *inputs;
    int *targets;
    // Store the averaged training loss after the last accumulated micro-batch completes.
    float mean_loss;
    float *accumulated_mean_loss;
    float *cpu_losses;
    // Keep a repeatable random-number state for operations such as stochastic rounding.
    unsigned long long rng_state;
    unsigned long long rng_state_last_update;
    int use_master_weights;
    bool init_state;
    int gelu_fusion;
    // Choose which activations to rebuild during backward instead of storing every copy.
    int recompute;

    int *workload_indices;
    int4 *bucket_info;

    // Enable the extra branch when this flag is nonzero.
    int use_adapters;
    // Set r, the narrow width inside each adapter.
    int adapter_dim;
    // Keep base weights fixed when adapters are enabled and this flag is set.
    int freeze_base;
    AdapterParams adapter;
    AdapterGrads adapter_grads;
    AdapterActs adapter_acts;
    void *adapter_params_mem;
    void *adapter_grads_mem;
    void *adapter_acts_mem;
    size_t adapter_param_elems;
} GPT2;

// Start the model with empty pointers and repeatable default settings.
// Null pointers let later code tell which GPU allocations still need creating.
void gpt2_init_common(GPT2 *model)
{

    model->acts_memory = NULL;
    model->inputs = NULL;
    model->targets = NULL;
    model->accumulated_mean_loss = NULL;
    model->cpu_losses = NULL;

    model->batch_size = 0;
    model->seq_len = 0;
    // Use -1 as a marker for no completed loss measurement yet.
    model->mean_loss = -1.0f;
    model->params_memory = NULL;

    model->grads_memory = NULL;
    model->workload_indices = NULL;
    model->bucket_info = NULL;

    model->m_memory = NULL;
    model->v_memory = NULL;
    model->master_weights = NULL;

    model->rng_state = 13371337 + multi_gpu_config.process_rank;
    model->use_master_weights = 1;
    model->init_state = true;
    model->recompute = 1;
    model->gelu_fusion = 0;

    model->use_adapters = 0;
    model->adapter_dim = 32;
    model->freeze_base = 1;
    model->adapter_params_mem = nullptr;
    model->adapter_grads_mem = nullptr;
    model->adapter_acts_mem = nullptr;
}
// Create the small adapter arrays separately from the base-model arrays.
// Each block gets its own down weights, down bias, up weights and up bias.
static void allocate_adapters(GPT2 *model, int B, int T)
{
    if (!model->use_adapters)
        return;
    int L = model->config.num_layers;
    int C = model->config.channels;
    int r = model->adapter_dim;
    // Count every block here. size_t keeps large array-size arithmetic wide enough.
    size_t ne_down_w = (size_t)L * C * r;
    size_t ne_down_b = (size_t)L * r;
    size_t ne_up_w = (size_t)L * r * C;
    size_t ne_up_b = (size_t)L * C;
    model->adapter_param_elems = ne_down_w + ne_down_b + ne_up_w + ne_up_b;
    // Convert an element count into bytes using the selected numeric type.
    size_t bytes = model->adapter_param_elems * sizeof(floatX);
    // Reserve GPU storage for adapter values; cudaCheck reports allocation errors.
    cudaCheck(cudaMalloc(&model->adapter_params_mem, bytes));
    // Reserve separate storage for derivatives, one per adapter parameter.
    cudaCheck(cudaMalloc(&model->adapter_grads_mem, bytes));
    // Clear the derivative arrays because later backward calls add into them.
    cudaCheck(cudaMemset(model->adapter_grads_mem, 0, bytes));

    // Walk through one allocation in bytes, assigning each parameter group a slice.
    char *p = (char *)model->adapter_params_mem;
    model->adapter.down_w = (floatX *)p;
    p += ne_down_w * sizeof(floatX);
    model->adapter.down_b = (floatX *)p;
    p += ne_down_b * sizeof(floatX);
    model->adapter.up_w = (floatX *)p;
    p += ne_up_w * sizeof(floatX);
    model->adapter.up_b = (floatX *)p;

    p = (char *)model->adapter_grads_mem;
    model->adapter_grads.down_w = (floatX *)p;
    p += ne_down_w * sizeof(floatX);
    model->adapter_grads.down_b = (floatX *)p;
    p += ne_down_b * sizeof(floatX);
    model->adapter_grads.up_w = (floatX *)p;
    p += ne_up_w * sizeof(floatX);
    model->adapter_grads.up_b = (floatX *)p;

    // Store one narrow hidden vector for every token in every block.
    size_t ne_h = (size_t)L * B * T * r;
    cudaCheck(cudaMalloc(&model->adapter_acts_mem, ne_h * sizeof(floatX)));
    model->adapter_acts.h = (floatX *)model->adapter_acts_mem;

    {
        floatX *tmp_down = (floatX *)mallocCheck(ne_down_w * sizeof(floatX));
        float *tmp_down_f32 = (float *)mallocCheck(ne_down_w * sizeof(float));
        mt19937_state rng;
        // Fix the random seed so repeated initializations choose the same values.
        manual_seed(&rng, 123);
        // Draw small down weights from a normal distribution: mean 0, standard deviation 0.02.
        // This randomizes starting weights, not the magnitude of a gradient.
        normal_(tmp_down_f32, ne_down_w, 0.0f, 0.02f, &rng);

        for (size_t i = 0; i < ne_down_w; i++) {
            // Convert the starting value into the precision used by this executable.
            tmp_down[i] = (floatX)tmp_down_f32[i];
        }
        // Copy the initialized down weights from CPU memory into GPU memory.
        cudaCheck(cudaMemcpy(model->adapter.down_w, tmp_down, ne_down_w * sizeof(floatX), cudaMemcpyHostToDevice));
        free(tmp_down_f32);
        free(tmp_down);

        cudaCheck(cudaMemset(model->adapter.down_b, 0, ne_down_b * sizeof(floatX)));
        // Zero up weights so the new branch initially adds no change to the base result.
        cudaCheck(cudaMemset(model->adapter.up_w, 0, ne_up_w * sizeof(floatX)));
        cudaCheck(cudaMemset(model->adapter.up_b, 0, ne_up_b * sizeof(floatX)));
    }
    printf0("adapters: r=%d params=%.2fM (%.2f MiB)\n",
            r, model->adapter_param_elems / 1e6,
            (double)bytes / 1024.0 / 1024.0);
}

// Add up the base-model storage and allocate it as one contiguous region.
// This reserves space; checkpoint loading or initialization fills its values.
void gpt2_allocate_weights(GPT2 *model)
{

    fill_in_parameter_sizes(model->param_elements, model->param_sizeof, model->config);
    model->num_parameters = 0;
    model->num_parameters_bytes = 0;
    for (int i = 0; i < NUM_PARAMETER_TENSORS; i++)
    {
        model->num_parameters += model->param_elements[i];
        model->num_parameters_bytes += model->param_elements[i] * model->param_sizeof[i];
    }

    assert(model->params_memory == nullptr);
    model->params_memory = malloc_and_point_parameters(&model->params, model->param_elements, model->param_sizeof);
}

// Reserve working arrays for gradients, activations and optimizer history.
// The inherited code still allocates base-model history even with a frozen base.
void gpt2_allocate_state(GPT2 *model, int B, int T)
{
    printf0("allocating %d MiB for parameter gradients\n", (int)round(model->num_parameters * sizeof(floatX) / (1024 * 1024)));
    assert(model->grads_memory == nullptr);
    model->grads_memory = malloc_and_point_parameters(&model->grads, model->param_elements, model->param_sizeof);

    model->batch_size = B;
    model->seq_len = T;

    fill_in_activation_sizes(&model->acts, model->acts_specs, B, T, model->config, model->recompute);
    model->acts_memory = malloc_and_point_activations(model->acts_specs);

    cudaCheck(cudaMalloc((void **)&model->inputs, B * T * sizeof(int)));
    cudaCheck(cudaMalloc((void **)&model->targets, B * T * sizeof(int)));
    cudaCheck(cudaMalloc(((void **)&model->accumulated_mean_loss), sizeof(float)));
    // Use pinned CPU memory so CUDA can transfer measured losses efficiently.
    cudaCheck(cudaMallocHost((void **)&model->cpu_losses, B * T * sizeof(float)));

    size_t num_c_groups = CEIL_DIV(model->config.channels, (WARP_SIZE * x128::size));
    assert((size_t)(model->batch_size * model->seq_len) * num_c_groups < (1ULL << 31ULL));
    model->workload_indices = (int *)mallocCheck(sizeof(int) * model->batch_size * model->seq_len * num_c_groups);
    model->bucket_info = (int4 *)mallocCheck(sizeof(int4) * model->batch_size * model->seq_len * num_c_groups);

    int memory_status = 0;

    size_t shard_num_parameters = multi_gpu_config.shard_num_parameters;
    printf0("allocating %zu MiB for AdamW optimizer state m\n", (shard_num_parameters * sizeof(float)) >> 20);
    printf0("allocating %zu MiB for AdamW optimizer state v\n", (shard_num_parameters * sizeof(float)) >> 20);
    assert(model->m_memory == nullptr);
    assert(model->v_memory == nullptr);
    memory_status |= cudaMallocConditionallyManaged((void **)&model->m_memory, shard_num_parameters * sizeof(float));
    memory_status |= cudaMallocConditionallyManaged((void **)&model->v_memory, shard_num_parameters * sizeof(float));

    // Keep a full-precision working copy for optimizer arithmetic when requested.
    if (model->use_master_weights == 1)
    {
        assert(model->master_weights == nullptr);
        printf0("allocating %zu MiB for master copy of params\n", (shard_num_parameters * sizeof(float)) >> 20);
        memory_status |= cudaMallocConditionallyManaged((void **)&model->master_weights, shard_num_parameters * sizeof(float));
    }

    int reduced_memory_status = (int)multi_gpu_cpu_float_sum((float)memory_status, &multi_gpu_config);
    if (reduced_memory_status >= 1)
    {
        printf0("WARNING: Fell back to cudaMallocManaged when initializing m,v,master_weights on %d GPUs\n", reduced_memory_status);
        printf0("         Prevents an OOM, but code may run much slower due to device <-> host memory movement\n");
    }

    // Ask CUDA how much GPU memory is currently free and how much exists in total.
    size_t free, total;
    cudaCheck(cudaMemGetInfo(&free, &total));
    printf0("device memory usage: %zd MiB / %zd MiB\n", (total - free) / 1024 / 1024, total / 1024 / 1024);

    size_t bytes_per_sequence = 0;
    for (size_t i = 0; i < NUM_ACTIVATION_TENSORS; i++)
    {
        bytes_per_sequence += model->acts_specs[i].size * sizeof_dtype(model->acts_specs[i].type) / B;
    }
    printf0("memory per sequence: %zu MiB\n", bytes_per_sequence / 1024 / 1024);
    printf0(" -> estimated maximum batch size: %zu\n", B + free / bytes_per_sequence);
}

// Save the base-model configuration and parameter arrays in a binary file.
// Adapter parameters use their own save function farther down.
void gpt2_write_to_checkpoint(GPT2 *model, const char *checkpoint_path)
{

    printf0("Writing model to %s\n", checkpoint_path);
    FILE *model_file = fopenCheck(checkpoint_path, "wb");

    int model_header[256];
    memset(model_header, 0, sizeof(model_header));
    model_header[0] = 20240326;
    assert(PRECISION_MODE == PRECISION_FP32 || PRECISION_MODE == PRECISION_BF16);
    model_header[1] = PRECISION_MODE == PRECISION_FP32 ? 3 : 5;
    model_header[2] = model->config.max_seq_len;
    model_header[3] = model->config.vocab_size;
    model_header[4] = model->config.num_layers;
    model_header[5] = model->config.num_heads;
    model_header[6] = model->config.channels;
    model_header[7] = model->config.padded_vocab_size;
    fwriteCheck(model_header, sizeof(int), 256, model_file);

    device_to_file(model_file, model->params_memory, model->num_parameters_bytes,
                   IO_BUF_SIZE, main_stream);

    fcloseCheck(model_file);
}

// Read a saved base model and check its format and numeric precision.
// The header describes how to interpret the numbers that follow it.
void gpt2_build_from_checkpoint(GPT2 *model, const char *checkpoint_path, bool weight_init = true)
{

    if (PRECISION_MODE == PRECISION_FP16)
    {

        fprintf(stderr, "build_from_checkpoint() does not support fp16 right now.\n");
        exit(EXIT_FAILURE);
    }

    FILE *model_file = fopenCheck(checkpoint_path, "rb");
    int model_header[256];
    freadCheck(model_header, sizeof(int), 256, model_file);
    if (model_header[0] != 20240326)
    {
        printf("Bad magic model file\n");
        exit(EXIT_FAILURE);
    }
    int version = model_header[1];
    if (!(version == 3 || version == 5))
    {

        fprintf(stderr, "Bad version in model file\n");
        fprintf(stderr, "---> HINT: try to re-run `python train_gpt2.py`\n");
        exit(EXIT_FAILURE);
    }

    if (weight_init)
    {
        if (PRECISION_MODE == PRECISION_BF16 && version != 5)
        {
            fprintf(stderr, "Precision is configured as BF16 but model at %s is not.\n", checkpoint_path);
            fprintf(stderr, "---> HINT: are you sure you're loading a _bf16.bin file?\n");
            exit(EXIT_FAILURE);
        }
        if (PRECISION_MODE == PRECISION_FP32 && version != 3)
        {
            fprintf(stderr, "Precision is configured as FP32 but model at %s is not.\n", checkpoint_path);
            fprintf(stderr, "---> HINT: to turn on FP32 you have to compile like: `make train_gpt2cu PRECISION=FP32`\n");
            fprintf(stderr, "---> HINT: are you sure you're loading a .bin file without any _bf16 in the name?\n");
            exit(EXIT_FAILURE);
        }
    }

    model->config.max_seq_len = model_header[2];
    model->config.vocab_size = model_header[3];
    model->config.num_layers = model_header[4];
    model->config.num_heads = model_header[5];
    model->config.channels = model_header[6];
    model->config.padded_vocab_size = model_header[7];

    gpt2_allocate_weights(model);

    if (weight_init)
    {
        assert(model->params_memory != NULL);
        file_to_device(model->params_memory, model_file, model->num_parameters_bytes, IO_BUF_SIZE, main_stream);
    }
    fcloseCheck(model_file);

    cudaCheck(cudaDeviceSynchronize());
}

// Choose a supported GPT-2 size from its depth, or number of blocks.
// Width and attention-head count must agree with that choice.
void gpt2_set_hyperparameters(GPT2Config *config, const char *depth_str)
{
    int depth = atoi(depth_str);
    assert(depth > 0);
    int channels, num_heads;
    if (depth == 6)
    {
        channels = 384;
        num_heads = 6;
    }
    else if (depth == 12)
    {
        channels = 768;
        num_heads = 12;
    }
    else if (depth == 24)
    {
        channels = 1024;
        num_heads = 16;
    }
    else if (depth == 36)
    {
        channels = 1280;
        num_heads = 20;
    }
    else if (depth == 48)
    {
        channels = 1600;
        num_heads = 25;
    }
    else if (depth == 60)
    {
        channels = 1920;
        num_heads = 30;
    }
    else if (depth == 72)
    {
        channels = 2880;
        num_heads = 30;
    }
    else if (depth == 84)
    {
        channels = 3456;
        num_heads = 36;
    }
    else
    {
        fprintf(stderr, "Unsupported GPT-2 depth: %d\n", depth);
        exit(EXIT_FAILURE);
    }
    config->num_layers = depth;
    config->channels = channels;
    config->num_heads = num_heads;
    config->max_seq_len = 1024;
}
// Run the small side path and add its result to the attention result.
// The input here is LN1(x); the x residual is added later in gpt2_forward.
void adapter_forward_add(
    floatX *out_btc,
    floatX *in_btc,
    floatX *h_btr,
    floatX *scratch_btc,
    floatX *down_w, floatX *down_b,
    floatX *up_w, floatX *up_b,
    int B, int T, int C, int r)
{

    // Mix C input features into r hidden features and add the down bias.
    matmul_forward_cublaslt(h_btr, in_btc, down_w, down_b, B, T, C, r, main_stream);
    // Apply GELU in place, smoothly scaling the hidden features by their values.
    gelu_forward(h_btr, h_btr, B * T * r, main_stream);

    // Mix r hidden features back into C output features and add the up bias.
    matmul_forward_cublaslt(scratch_btc, h_btr, up_w, up_b, B, T, r, C, main_stream);

    // Add the adapter correction to the attention output, element by element.
    residual_forward(out_btc, out_btc, scratch_btc, B * T * C, main_stream);
}
// Select an optional GPT-3-style configuration by width.
// This configuration helper is inherited; it is not another adapter design.
void gpt3_set_hyperparameters(GPT2Config *config, const char *channels_str)
{

    int channels = atoi(channels_str);
    assert(channels > 0);
    int depth, head_size;
    if (channels == 384)
    {
        depth = 6;
        head_size = 64;
    }
    else if (channels == 768)
    {
        depth = 12;
        head_size = 64;
    }
    else if (channels == 1024)
    {
        depth = 24;
        head_size = 64;
    }
    else if (channels == 1536)
    {
        depth = 24;
        head_size = 96;
    }
    else if (channels == 2048)
    {
        depth = 24;
        head_size = 128;
    }
    else if (channels == 2560)
    {
        depth = 32;
        head_size = 80;
    }
    else if (channels == 4096)
    {
        depth = 32;
        head_size = 128;
    }
    else if (channels == 5140)
    {
        depth = 40;
        head_size = 128;
    }
    else if (channels == 12288)
    {
        depth = 96;
        head_size = 128;
    }
    else
    {
        fprintf(stderr, "Unsupported GPT-3 channels: %d\n", channels);
        exit(EXIT_FAILURE);
    }
    assert(channels % head_size == 0);
    config->num_layers = depth;
    config->channels = channels;
    config->num_heads = channels / head_size;
    config->max_seq_len = 2048;
}

// Build a base model from a size label rather than a checkpoint.
// Layer-normalization scales start at one; ordinary biases start at zero.
void gpt_build_from_descriptor(GPT2 *model, const char *descriptor)
{

    assert(descriptor != NULL);
    size_t len = strlen(descriptor);
    if (len > 1 && descriptor[0] == 'd')
    {
        gpt2_set_hyperparameters(&model->config, descriptor + 1);
    }
    else if (len > 6 && strncmp(descriptor, "gpt2:d", 6) == 0)
    {
        gpt2_set_hyperparameters(&model->config, descriptor + 6);
    }
    else if (len > 6 && strncmp(descriptor, "gpt3:c", 6) == 0)
    {
        gpt3_set_hyperparameters(&model->config, descriptor + 6);
    }
    else
    {
        fprintf(stderr, "Unsupported model descriptor: %s\n", descriptor);
        exit(EXIT_FAILURE);
    }

    model->config.vocab_size = 50257;
    model->config.padded_vocab_size = 50304;

    gpt2_allocate_weights(model);

    mt19937_state init_rng;
    manual_seed(&init_rng, 42);
    floatX *params_memory_cpu = (floatX *)mallocCheck(model->num_parameters_bytes);
    memset(params_memory_cpu, 0, model->num_parameters_bytes);

    float residual_scale = 1.0f / sqrtf(2.0f * model->config.num_layers);

    size_t L = model->config.num_layers;
    size_t offset = 0;
    // Visit blocks from input to output; l selects that block's own weights.
    for (int l = 0; l < L; l++)
    {
        offset = 0;
        for (int i = 0; i < NUM_PARAMETER_TENSORS; i++)
        {

            if (l == 0 && (i == 2 || i == 8 || i == 14))
            {
                for (size_t j = 0; j < model->param_elements[i]; j++)
                {
                    params_memory_cpu[offset + j] = 1.0f;
                }
            }

            if ((l == 0 && (i == 0 || i == 1))
                || i == 4 || i == 6 || i == 10 || i == 12)
            {
                size_t n = model->param_elements[i];
                size_t layer_offset = 0;
                if (i == 0)
                {

                    n = model->config.vocab_size * model->config.channels;
                }
                if (i == 4 || i == 6 || i == 10 || i == 12)
                {

                    assert(n % L == 0);
                    n = n / L;
                    layer_offset = l * n;
                }

                float scale = (i == 6 || i == 12) ? 0.02f * residual_scale : 0.02f;

                float *fp32_buffer = (float *)mallocCheck(n * sizeof(float));
                normal_(fp32_buffer, n, 0.0f, scale, &init_rng);
                for (size_t j = 0; j < n; j++)
                {
                    params_memory_cpu[offset + layer_offset + j] = (floatX)fp32_buffer[j];
                }
                free(fp32_buffer);
            }
            offset += model->param_elements[i];
        }
    }

    cudaCheck(cudaMemcpy(model->params_memory, params_memory_cpu, model->num_parameters_bytes, cudaMemcpyHostToDevice));
    free(params_memory_cpu);
}

// Print a few GPU values when debugging an array.
// This helper does not calculate loss or assess training quality.
__global__ void print_adapter_params(floatX *item, size_t n, char *hint)
{
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n)
    {
        printf("%s - %d: %f ", hint, idx, (float)item[idx]);
    }
}

// Turn token IDs into next-token scores without changing any weights.
// Follow one block through attention, the adapter branch and the larger MLP.
void gpt2_forward(GPT2 *model, const int *inputs, size_t B, size_t T)
{
    NVTX_RANGE_FN();

    // Stop if base weights have not been allocated; forward needs valid arrays.
    if (model->params_memory == NULL)
    {
        printf("Error: model was not initialized properly.\n");
        exit(EXIT_FAILURE);
    }

    const size_t V = model->config.vocab_size;
    const size_t Vp = model->config.padded_vocab_size;
    const size_t L = model->config.num_layers;
    const size_t NH = model->config.num_heads;
    const size_t C = model->config.channels;

    // Smaller inference batches fit existing buffers; larger ones would overrun them.
    if (B > model->batch_size || T > model->seq_len)
    {
        printf("Model: B=%d T=%d, Desired: B=%d T=%d\n", model->batch_size, model->seq_len, (int)B, (int)T);
        exit(EXIT_FAILURE);
    }

    // Move the token IDs to the GPU before looking up their feature vectors.
    cudaCheck(cudaMemcpy(model->inputs, inputs, B * T * sizeof(int), cudaMemcpyHostToDevice));

    // Reject token IDs outside the real vocabulary before they index an array.
    tokenCheck(inputs, B * T, V);

    ParameterTensors params = model->params;
    ActivationTensors acts = model->acts;
    // Combine token embeddings and position embeddings to form the first block input.
    encoder_forward(acts.encoded, model->inputs, params.wte, params.wpe, B, T, C, main_stream);

    layernorm_forward((model->recompute < 2) ? acts.ln1 : acts.lnf, acts.ln1_mean, acts.ln1_rstd, acts.encoded, params.ln1w, params.ln1b, B, T, C, main_stream);

    // Visit blocks from input to output; l selects that block's own weights.
    for (int l = 0; l < L; l++)
    {
        NvtxRange layer_range("Layer", l);

        // Use embeddings for block zero, then the previous block output for later blocks.
        floatX *residual = l == 0 ? acts.encoded : acts.residual3 + (l - 1) * B * T * C;

        floatX *l_qkvw = params.qkvw + l * 3 * C * C;
        floatX *l_qkvb = params.qkvb + l * 3 * C;
        floatX *l_attprojw = params.attprojw + l * C * C;
        floatX *l_attprojb = params.attprojb + l * C;
        floatX *l_ln2w = params.ln2w + l * C;
        floatX *l_ln2b = params.ln2b + l * C;
        floatX *l_fcw = params.fcw + l * 4 * C * C;
        floatX *l_fcb = params.fcb + l * 4 * C;
        floatX *l_fcprojw = params.fcprojw + l * C * 4 * C;
        floatX *l_fcprojb = params.fcprojb + l * C;

        floatX *l_ln1 = (model->recompute < 2) ? acts.ln1 + l * B * T * C : acts.lnf;
        floatX *l_qkvr = acts.qkvr + l * B * T * 3 * C;
        floatX *l_atty = acts.atty + l * B * T * C;
        floatX *l_residual2 = acts.residual2 + l * B * T * C;
        floatX *l_ln2 = (model->recompute < 2) ? acts.ln2 + l * B * T * C : acts.lnf;
        float *l_ln2_mean = acts.ln2_mean + l * B * T;
        float *l_ln2_rstd = acts.ln2_rstd + l * B * T;
        floatX *l_fch = acts.fch + l * B * T * 4 * C;

        floatX *l_fch_gelu = (model->recompute < 1) ? acts.fch_gelu + l * B * T * 4 * C : acts.fch_gelu;
        floatX *l_residual3 = acts.residual3 + l * B * T * C;
        floatX *scratch = (floatX *)acts.output;

#ifdef ENABLE_CUDNN
        float *l_att = (float *)acts.att + l * B * NH * T;
        matmul_forward_cublaslt(l_qkvr, l_ln1, l_qkvw, l_qkvb, B, T, C, 3 * C, main_stream);
        attention_forward_cudnn(l_atty, (float *)l_att, l_qkvr, B, T, NH, C, main_stream);
#else
        floatX *l_att = acts.att + l * B * NH * T * T;
        if (T != model->seq_len)
        {
            cudaCheck(cudaMemset(l_att, 0, B * NH * T * T * sizeof(floatX)));
        }

        matmul_forward_cublaslt(scratch, l_ln1, l_qkvw, l_qkvb, B, T, C, 3 * C, main_stream);
        // Form attention features from queries, keys and values, respecting the causal mask.
        attention_forward(l_atty, l_qkvr, l_att, scratch, B, T, C, NH, main_stream);
#endif
        // Project the attention-head result back to C features before adding the adapter.
        matmul_forward_cublaslt(scratch, l_atty, l_attprojw, l_attprojb, B, T, C, C, main_stream);

        if (model->use_adapters)
        {

            int r = model->adapter_dim;
            floatX *h = model->adapter_acts.h + (size_t)l * B * T * r;
            floatX *dw = model->adapter.down_w + (size_t)l * C * r;
            floatX *db = model->adapter.down_b + (size_t)l * r;
            floatX *uw = model->adapter.up_w + (size_t)l * r * C;
            floatX *ub = model->adapter.up_b + (size_t)l * C;

            // Read LN1(x) on a parallel branch and add its correction to attention.
            // The following residual sum also adds x, matching the supplied diagram.
            adapter_forward_add(scratch, l_ln1, h, acts.scratch_btc, dw, db, uw, ub, B, T, C, r);
        }

        if (model->use_adapters)
        {

            // Add x to the combined attention and adapter result: y = x + a + delta.
            residual_forward(l_residual2, residual, scratch, B * T * C, main_stream);
            // Normalize y before the block's larger feed-forward network.
            layernorm_forward(l_ln2, l_ln2_mean, l_ln2_rstd, l_residual2, l_ln2w, l_ln2b, B, T, C, main_stream);
        }
        else
        {
            fused_residual_forward5(l_residual2, l_ln2, l_ln2_mean, l_ln2_rstd,
                                    residual, scratch, l_ln2w, l_ln2b, B * T, C, main_stream);
        }

        // Expand C features to 4*C and apply GELU, optionally fused into the multiplication.
        matmul_forward_cublaslt(l_fch_gelu, l_ln2, l_fcw, l_fcb, B, T, C, 4 * C, main_stream, l_fch, model->gelu_fusion);
        // Bring the feed-forward output back to C so the second residual sum can add it to y.
        matmul_forward_cublaslt(scratch, l_fch_gelu, l_fcprojw, l_fcprojb, B, T, 4 * C, C, main_stream);

        if (l + 1 != L)
        {
            floatX *l_ln1 = (model->recompute < 2) ? acts.ln1 + (l + 1) * B * T * C : acts.lnf;
            float *l_ln1_mean = acts.ln1_mean + (l + 1) * B * T;
            float *l_ln1_rstd = acts.ln1_rstd + (l + 1) * B * T;
            const floatX *l_ln1w = params.ln1w + (l + 1) * C;
            const floatX *l_ln1b = params.ln1b + (l + 1) * C;
            fused_residual_forward5(l_residual3, l_ln1, l_ln1_mean, l_ln1_rstd, l_residual2, scratch, l_ln1w, l_ln1b,
                                    B * T, C, main_stream);
        }
        else
        {
            fused_residual_forward5(l_residual3, acts.lnf, acts.lnf_mean, acts.lnf_rstd, l_residual2, scratch,
                                    params.lnfw, params.lnfb,
                                    B * T, C, main_stream);
        }
    }

    // Score next-token candidates using the same token weights used for input embeddings.
    matmul_forward_cublaslt(acts.output, acts.lnf, params.wte, NULL, B, T, C, Vp, main_stream);
    cudaCheck(cudaDeviceSynchronize());
}

// Measure average next-token cross-entropy on the supplied text.
// The classifier leaves logits intact here and does not write their gradients.
float gpt2_validate(GPT2 *model, const int *inputs, const int *targets, size_t B, size_t T)
{
    // Require the real next-token answers before attempting a loss measurement.
    assert(targets != NULL);

    gpt2_forward(model, inputs, B, T);

    const size_t V = model->config.vocab_size;
    const size_t Vp = model->config.padded_vocab_size;

    NvtxRange classifier_and_loss_range("classifier_and_loss");
    ActivationTensors acts = model->acts;
    float mean_loss = 0.0f;

    // Use the token-average scale if derivatives are requested; validation disables them.
    const float dloss = 1.0f / (B * T);

    cudaCheck(cudaMemset(acts.losses, 0, B * T * sizeof(float)));
    cudaCheck(cudaMemcpy(model->targets, targets, B * T * sizeof(int), cudaMemcpyHostToDevice));
    // Check that every expected answer is a valid vocabulary ID.
    tokenCheck(targets, B * T, V);
    // Calculate per-token loss without replacing logits with backward derivatives.
    fused_classifier(acts.output, acts.losses, dloss, model->targets, B, T, V, Vp, std::false_type{}, main_stream);
    cudaCheck(cudaMemcpy(model->cpu_losses, acts.losses, B * T * sizeof(float), cudaMemcpyDeviceToHost));
    for (int i = 0; i < B * T; i++)
    {
        mean_loss += model->cpu_losses[i];
    }
    // Average the per-token losses so changing batch length does not just scale the sum.
    mean_loss /= B * T;
    cudaCheck(cudaDeviceSynchronize());
    return mean_loss;
}

// Trace loss backward through the layers and accumulate weight derivatives.
// The adapter-specific section below retains known gradient-buffer defects.
void gpt2_backward_and_reduce(GPT2 *model, int *inputs, const int *targets, int grad_accum_steps, int micro_step)
{
    // Backward needs allocated derivative storage before any kernel writes to it.
    if (model->grads_memory == nullptr)
    {
        fprintf(stderr, "Need to allocate gradients before backward");
        exit(EXIT_FAILURE);
    }
    NVTX_RANGE_FN();
    // Only the last micro-batch completes this step's accumulated gradients.
    bool last_step = micro_step == grad_accum_steps - 1;

    // Clear old gradients once per optimizer step, then add each micro-batch contribution.
    if (micro_step == 0)
    {

        cudaCheck(cudaMemsetAsync(model->acts.losses, 0, model->batch_size * model->seq_len * sizeof(float), main_stream));
        cudaCheck(cudaMemsetAsync(model->grads_memory, 0, model->num_parameters * sizeof(floatX), main_stream));
        if (model->use_adapters)
        {
            cudaCheck(cudaMemsetAsync(model->adapter_grads_mem, 0,
                                      model->adapter_param_elems * sizeof(floatX), main_stream));
        }
    }

    const size_t B = model->batch_size;
    const size_t T = model->seq_len;
    const size_t V = model->config.vocab_size;
    const size_t Vp = model->config.padded_vocab_size;
    const size_t L = model->config.num_layers;
    const size_t NH = model->config.num_heads;
    const size_t C = model->config.channels;

    ParameterTensors params = model->params;
    ParameterTensors grads = model->grads;
    ActivationTensors acts = model->acts;

    NvtxRange classifier_and_loss_range("classifier_and_loss");
    // Scale loss derivatives so all micro-batches together represent a token average.
    const float dloss = 1.0f / (float)(B * T * grad_accum_steps);
    cudaCheck(cudaMemcpy(model->targets, targets, B * T * sizeof(int), cudaMemcpyHostToDevice));
    // Check that every expected answer is a valid vocabulary ID.
    tokenCheck(targets, B * T, V);
    // Calculate loss and replace logits with the derivatives that start backward.
    fused_classifier(acts.output, acts.losses, dloss, model->targets, B, T, V, Vp, std::true_type{}, main_stream);

    // Hold the live residual-stream derivative in scratch_btc.
    // The adapter section below incorrectly reuses this storage; watch that alias.
    floatX *dresidual = (floatX *)model->acts.scratch_btc;
    cudaCheck(cudaMemset(dresidual, 0, B * T * C * sizeof(floatX)));

    float *scratchF = (float *)acts.output;
    floatX *scratchX = (floatX *)acts.output;

    matmul_backward(model->acts.scratch_bt4c, grads.wte, NULL, acts.output, acts.lnf, params.wte, NULL, B, T, C, Vp, main_stream);

    floatX *residual = acts.residual3 + (L - 1) * B * T * C;
    layernorm_backward(dresidual, grads.lnfw, grads.lnfb, scratchF, model->acts.scratch_bt4c, residual, params.lnfw, acts.lnf_mean, acts.lnf_rstd, B, T, C, main_stream);

    floatX *dl_btc = residual;

    // Work from the last block toward the first because each derivative depends on later work.
    for (int l = L - 1; l >= 0; l--)
    {
        NvtxRange layer_range("Layer", l);

        residual = l == 0 ? acts.encoded : acts.residual3 + (l - 1) * B * T * C;

        floatX *l_ln1w = params.ln1w + l * C;
        floatX *l_ln1b = params.ln1b + l * C;
        floatX *l_qkvw = params.qkvw + l * 3 * C * C;
        floatX *l_attprojw = params.attprojw + l * C * C;
        floatX *l_ln2w = params.ln2w + l * C;
        floatX *l_ln2b = params.ln2b + l * C;
        floatX *l_fcw = params.fcw + l * 4 * C * C;
        floatX *l_fcprojw = params.fcprojw + l * C * 4 * C;

        floatX *dl_ln1w = grads.ln1w + l * C;
        floatX *dl_ln1b = grads.ln1b + l * C;
        floatX *dl_qkvw = grads.qkvw + l * 3 * C * C;
        floatX *dl_qkvb = grads.qkvb + l * 3 * C;
        floatX *dl_attprojw = grads.attprojw + l * C * C;
        floatX *dl_attprojb = grads.attprojb + l * C;
        floatX *dl_ln2w = grads.ln2w + l * C;
        floatX *dl_ln2b = grads.ln2b + l * C;
        floatX *dl_fcw = grads.fcw + l * 4 * C * C;
        floatX *dl_fcb = grads.fcb + l * 4 * C;
        floatX *dl_fcprojw = grads.fcprojw + l * C * 4 * C;
        floatX *dl_fcprojb = grads.fcprojb + l * C;

        floatX *l_ln1 = (model->recompute < 2) ? acts.ln1 + l * B * T * C : acts.lnf;
        float *l_ln1_mean = acts.ln1_mean + l * B * T;
        float *l_ln1_rstd = acts.ln1_rstd + l * B * T;
        floatX *l_qkvr = acts.qkvr + l * B * T * 3 * C;
        floatX *l_atty = acts.atty + l * B * T * C;
        floatX *l_residual2 = acts.residual2 + l * B * T * C;
        floatX *l_ln2 = (model->recompute < 2) ? acts.ln2 + l * B * T * C : acts.lnf;
        float *l_ln2_mean = acts.ln2_mean + l * B * T;
        float *l_ln2_rstd = acts.ln2_rstd + l * B * T;
        floatX *l_fch_pre_gelu = acts.fch + l * B * T * 4 * C;
        floatX *l_fch_gelu = (model->recompute < 1) ? acts.fch_gelu + l * B * T * 4 * C : acts.fch_gelu;

        floatX *dl_bt4c = (floatX *)model->acts.scratch_bt4c;

        if (model->recompute >= 1)
        {

            gelu_forward(l_fch_gelu, l_fch_pre_gelu, B * T * 4 * C, main_stream);
        }
        matmul_backward(dl_bt4c, dl_fcprojw, dl_fcprojb, dresidual, l_fch_gelu, l_fcprojw, scratchF, B, T, 4 * C, C, main_stream, l_fch_pre_gelu, model->gelu_fusion);
        if (model->recompute >= 2)
        {

            // Normalize y before the block's larger feed-forward network.
            layernorm_forward(l_ln2, l_ln2_mean, l_ln2_rstd, l_residual2, l_ln2w, l_ln2b, B, T, C, main_stream);
        }
        matmul_backward(dl_btc, dl_fcw, dl_fcb, dl_bt4c, l_ln2, l_fcw, scratchF, B, T, C, 4 * C, main_stream);

        layernorm_backward(dresidual, dl_ln2w, dl_ln2b, scratchF, dl_btc, l_residual2, l_ln2w, l_ln2_mean, l_ln2_rstd, B, T, C, main_stream);

        // Inherited defect: this is the same memory as dresidual, not an independent copy.
        floatX* d_scratch = acts.scratch_btc;
        cudaCheck(cudaMemcpyAsync(d_scratch, dresidual, B*T*C*sizeof(floatX), cudaMemcpyDeviceToDevice, main_stream));

        matmul_backward(dl_btc, dl_attprojw, dl_attprojb, d_scratch, l_atty, l_attprojw, scratchF, B, T, C, C, main_stream);
#ifdef ENABLE_CUDNN
        float *l_att = (float *)acts.att + l * B * NH * T;
        attention_backward_cudnn(dl_bt4c, dl_btc, l_qkvr, l_atty, (float *)l_att, B, T, NH, C, main_stream);
#else
        floatX *l_att = acts.att + l * B * NH * T * T;

        floatX *buffer_a = l_atty;
        floatX *buffer_b = l_fch_pre_gelu;
        attention_backward(dl_bt4c, buffer_b, scratchX, buffer_a, dl_btc, l_qkvr, l_att, B, T, C, NH, main_stream);
#endif

        floatX* dx_main_path = dl_bt4c;

        if (model->use_adapters)
        {
            int r = model->adapter_dim;

            floatX *x = l_ln1;
            floatX *h = model->adapter_acts.h + (size_t)l * B * T * r;
            floatX *dw = model->adapter.down_w + (size_t)l * C * r;
            floatX *db = model->adapter.down_b + (size_t)l * r;
            floatX *uw = model->adapter.up_w + (size_t)l * r * C;
            floatX *ub = model->adapter.up_b + (size_t)l * C;

            floatX *g_dw = model->adapter_grads.down_w + (size_t)l * C * r;
            floatX *g_db = model->adapter_grads.down_b + (size_t)l * r;
            floatX *g_uw = model->adapter_grads.up_w + (size_t)l * r * C;
            floatX *g_ub = model->adapter_grads.up_b + (size_t)l * C;

            // Backpropagate through the up projection to get derivatives for hidden features.
            floatX* dh = dl_btc;
            matmul_backward(dh, g_uw, g_ub, d_scratch, h, uw, scratchF, B, T, r, C, main_stream);

            // Inherited defect: this recomputation overwrites the live residual derivative.
            floatX* h_pre_gelu = acts.scratch_btc;
            matmul_forward_cublaslt(h_pre_gelu, x, dw, db, B, T, C, r, main_stream);
            // Multiply hidden derivatives by GELU's local slope using the pre-GELU values.
            gelu_backward_inplace(dh, h_pre_gelu, B * T * r, main_stream);

            // Inherited defect: clearing this array also clears the aliased residual derivative.
            floatX *dx_adapter = d_scratch;
            cudaCheck(cudaMemsetAsync(dx_adapter, 0, B * T * C * sizeof(floatX), main_stream));
            matmul_backward(dx_adapter, g_dw, g_db, dh, x, dw, scratchF, B, T, C, r, main_stream);

            // Inherited defect: a C-wide input derivative is added before the 3*C QKV projection.
            // Those branches should join after the QKV input derivative reaches the C-wide LN1 input.
            residual_forward(dx_main_path, dx_main_path, dx_adapter, B*T*C, main_stream);
        }

        if (model->recompute >= 2)
        {
            layernorm_forward(l_ln1, l_ln1_mean, l_ln1_rstd, residual, l_ln1w, l_ln1b, B, T, C, main_stream);
        }

        matmul_backward(dl_btc, dl_qkvw, dl_qkvb, dx_main_path, l_ln1, l_qkvw, scratchF, B, T, C, 3 * C, main_stream);

        layernorm_backward(dresidual, dl_ln1w, dl_ln1b, scratchF, dl_btc, residual, l_ln1w, l_ln1_mean, l_ln1_rstd, B, T, C, main_stream);

        // Combine GPU results only after all micro-batches for this step are finished.
        if (last_step)
        {
            floatX *const pointers[] = {
                dl_ln1w, dl_ln1b,
                dl_qkvw, dl_qkvb,
                dl_attprojw, dl_attprojb,
                dl_ln2w, dl_ln2b,
                dl_fcw, dl_fcb,
                dl_fcprojw, dl_fcprojb};
            const size_t nelem[] = {
                C, C,
                3 * C * C, 3 * C,
                C * C, C,
                C, C,
                4 * C * C, 4 * C,
                C * 4 * C, C};
            multi_gpu_async_reduce_gradient(pointers, nelem, &multi_gpu_config, main_stream);
        }
    }
    encoder_backward(grads.wte, grads.wpe, scratchX, model->workload_indices, model->bucket_info,
                     dresidual, model->inputs, inputs, B, T, C, random_u32(&model->rng_state), main_stream);

    if (last_step)
    {

        global_sum_deterministic(model->accumulated_mean_loss, acts.losses, B * T, main_stream);

#if MULTI_GPU
        ncclCheck(ncclAllReduce(model->accumulated_mean_loss, model->accumulated_mean_loss, sizeof(float), ncclFloat, ncclAvg, multi_gpu_config.nccl_comm, main_stream));
#endif
        cudaCheck(cudaMemcpyAsync(&model->mean_loss, model->accumulated_mean_loss, sizeof(float), cudaMemcpyDeviceToHost, main_stream));

        floatX *const pointers[] = {grads.wte, grads.wpe, grads.lnfw, grads.lnfb};
        const size_t nelem[] = {Vp * C, T * C, C, C};
        multi_gpu_async_reduce_gradient(pointers, nelem, &multi_gpu_config, main_stream);
    }

    cudaCheck(cudaDeviceSynchronize());
    if (last_step)
    {
        model->mean_loss /= B * T * grad_accum_steps;
    }
    else
    {
        model->mean_loss = -1.f;
    }
}

// Find one weight array inside the packed base-model allocation.
// Block-specific arrays need an extra offset to reach the requested block.
ShardInfo gpt2_get_tensor_at_layer(const GPT2 *model, int layer_id, int param_tensor_id)
{

    ptrdiff_t offset = 0;
    for (int i = 0; i < param_tensor_id; i++)
    {
        offset += (ptrdiff_t)model->param_elements[i];
    }
    size_t size = model->param_elements[param_tensor_id];

    if (2 <= param_tensor_id && param_tensor_id <= 13)
    {
        size /= model->config.num_layers;
        offset += (ptrdiff_t)(layer_id * size);
    }
    return {offset, size};
}

// Measure the combined size of the base-model gradients.
// This inherited calculation excludes the separate adapter gradient allocation.
float gpt2_calculate_grad_norm(GPT2 *model, MultiGpuConfig *multi_gpu_config)
{
    NVTX_RANGE_FN();
    floatX *grads_memory = (floatX *)model->grads_memory;

    float *grad_norm_squared = (float *)model->acts.output;
    // Collect the GPU's summed squares on the CPU before taking their square root.
    float grad_norm_squared_cpu = 0.0f;

    int num_slices[2] = {1, model->config.num_layers};
    int max_num_block_sums = get_max_num_block_sums(num_slices, 2);
    if (multi_gpu_config->zero_stage == 1)
    {

        for (int i = 0; i < NUM_PARAMETER_TENSORS; i++)
        {
            ShardInfo tensor = gpt2_get_tensor_at_layer(model, 0, i);
            ShardInfo shard = multi_gpu_get_shard_offset(tensor.size, multi_gpu_config, 1);
            ptrdiff_t offset = tensor.offset + shard.offset;
            bool is_first_pass = (i == 0);
            if ((i < 2 || i > 13))
            {
                global_norm_squared(grad_norm_squared, grads_memory + offset, shard.size, 0, 1,
                                    max_num_block_sums, is_first_pass, main_stream);
            }
            else
            {
                global_norm_squared(grad_norm_squared, grads_memory + offset, shard.size, tensor.size, model->config.num_layers,
                                    max_num_block_sums, is_first_pass, main_stream);
            }
        }
        global_sum_deterministic(grad_norm_squared, grad_norm_squared, max_num_block_sums, main_stream);
#if MULTI_GPU

        ncclCheck(ncclAllReduce(grad_norm_squared, grad_norm_squared, sizeof(float), ncclFloat, ncclSum, multi_gpu_config->nccl_comm, main_stream));
#endif
    }
    else
    {

        global_norm_squared(grad_norm_squared, grads_memory, model->num_parameters, 0, 1, max_num_block_sums, true, main_stream);
        global_sum_deterministic(grad_norm_squared, grad_norm_squared, max_num_block_sums, main_stream);
    }
    cudaCheck(cudaMemcpy(&grad_norm_squared_cpu, grad_norm_squared, sizeof(float), cudaMemcpyDeviceToHost));
    // Take the square root of summed squared gradients to get their overall size.
    float grad_norm_cpu = sqrtf(grad_norm_squared_cpu);
    return grad_norm_cpu;
}

// Apply AdamW updates using gradients, learning rate and stored history.
// The base-freeze switch skips base updates; adapter state sharing remains a defect.
void gpt2_update(GPT2 *model, float learning_rate, float beta1, float beta2, float eps, float weight_decay, float grad_scale, int t,
                 MultiGpuConfig *multi_gpu_config, bool init_from_master_only = false)
{

    NVTX_RANGE_FN();
    if (model->grads_memory == nullptr || model->m_memory == nullptr || model->v_memory == nullptr)
    {
        fprintf(stderr, "Need to allocate optimizer state before update");
        exit(EXIT_FAILURE);
    }

    // Initialize optimizer history on the first update rather than reading old memory.
    bool init_state = model->init_state;
    if (init_state)
    {
        model->init_state = false;
        NvtxRange rng("InitOpt");
        cudaCheck(cudaMemset(model->m_memory, 0, multi_gpu_config->shard_num_parameters * sizeof(float)));
        cudaCheck(cudaMemset(model->v_memory, 0, multi_gpu_config->shard_num_parameters * sizeof(float)));
    }

    // Remember the rounding state so checkpoint restoration can repeat the same choices.
    model->rng_state_last_update = model->rng_state;
    // Skip base-weight optimizer updates in adapter-only mode; backward still ran through the base.
    if (model->use_adapters && model->freeze_base)
    {
    }
    else
    {

        for (int i = 0; i < NUM_PARAMETER_TENSORS; i++)
        {

            // Advance a repeatable random sequence for stochastic rounding inside the optimizer.
            // This changes rounding choices; it does not randomly rescale gradients.
            unsigned int seed = random_u32(&model->rng_state);

            int num_layers = model->config.num_layers;
            if ((i < 2 || i > 13))
            {
                num_layers = 1;
            }

            ShardInfo tensor = gpt2_get_tensor_at_layer(model, 0, i);
            ShardInfo shard = multi_gpu_get_shard_offset(tensor.size, multi_gpu_config, 1);
            ptrdiff_t local_offset_full = tensor.offset + shard.offset;
            ptrdiff_t local_offset_partial = tensor.offset / multi_gpu_config->num_processes;

            // Apply weight decay to matrix weights while leaving biases and normalization scales alone.
        float wd = (i == 0 || i == 1 || i == 4 || i == 6 || i == 10 || i == 12) ? weight_decay : 0.0f;
            floatX *param_ptr = (floatX *)model->params_memory + local_offset_full;
            floatX *grad_ptr = (floatX *)model->grads_memory + local_offset_full;

            ptrdiff_t opt_state_offset = multi_gpu_config->zero_stage < 1 ? local_offset_full : local_offset_partial;
            float *m_ptr = model->m_memory + opt_state_offset;
            float *v_ptr = model->v_memory + opt_state_offset;
            float *master_ptr = nullptr;
            if (model->master_weights != nullptr)
            {
                master_ptr = model->master_weights + opt_state_offset;
            }
            if (init_state && model->master_weights != nullptr)
            {
                size_t grid_size = CEIL_DIV(shard.size, 512);
                copy_and_cast_kernel<<<dim3(grid_size, num_layers), 512, 0, main_stream>>>(master_ptr, param_ptr, shard.size,
                                                                                           shard.size, tensor.size);
                cudaCheck(cudaGetLastError());
            }

            if (init_from_master_only)
            {

                init_from_master(param_ptr, master_ptr, shard.size, tensor.size, shard.size, num_layers, seed, main_stream);
            }
            else
            {

                adamw_update(param_ptr, master_ptr, grad_ptr,
                             m_ptr, v_ptr,
                             shard.size, tensor.size, tensor.size, shard.size, num_layers,
                             learning_rate,
                             beta1, beta2, t, eps, wd, grad_scale, seed, main_stream);
            }

            if (multi_gpu_config->zero_stage == 1)
            {
#if MULTI_GPU
                ncclCheck(ncclGroupStart());
                for (int l = 0; l < num_layers; ++l)
                {

                    ncclCheck(ncclAllGather(param_ptr + l * tensor.size,
                                            (floatX *)model->params_memory + tensor.offset + l * tensor.size,
                                            shard.size, ncclFloatX,
                                            multi_gpu_config->nccl_comm, multi_gpu_config->nccl_stream));
                }
                ncclCheck(ncclGroupEnd());
#endif
            }
        }
    }

    if (model->use_adapters)
    {
        int L = model->config.num_layers;
        int C = model->config.channels;
        int r = model->adapter_dim;

        // Inherited defect: all four calls below reuse the front of the same history arrays.
        // Each adapter tensor needs its own moments and correctly initialized master weights.
        auto upd = [&](floatX *w, floatX *g, size_t n, float wd)
        {
            // Advance a repeatable random sequence for stochastic rounding inside the optimizer.
            // This changes rounding choices; it does not randomly rescale gradients.
            unsigned int seed = random_u32(&model->rng_state);

            adamw_update(w, model->master_weights ? model->master_weights : nullptr,
                         g, model->m_memory, model->v_memory,
                         n, n, n, n, 1,
                         learning_rate, beta1, beta2, t, eps, wd, grad_scale, seed, main_stream);
        };
        size_t ne_up_w = (size_t)L * r * C;
        size_t ne_up_b = (size_t)L * C;
        // Count every block here. size_t keeps large array-size arithmetic wide enough.
    size_t ne_down_w = (size_t)L * C * r;
        size_t ne_down_b = (size_t)L * r;

        upd(model->adapter.up_w, model->adapter_grads.up_w, ne_up_w, weight_decay);
        upd(model->adapter.up_b, model->adapter_grads.up_b, ne_up_b, 0.0f);
        upd(model->adapter.down_w, model->adapter_grads.down_w, ne_down_w, weight_decay);
        upd(model->adapter.down_b, model->adapter_grads.down_b, ne_down_b, 0.0f);
    }

    cudaCheck(cudaDeviceSynchronize());
}

// Estimate how much advertised GPU arithmetic capacity the step used.
// This is a rough model of utilization, not a direct speed or quality measurement.
float gpt2_estimate_mfu(GPT2 *model, int num_tokens, float dt)
{

    size_t N = model->num_parameters;
    int L = model->config.num_layers;
    int C = model->config.channels;
    int T = model->seq_len;
    size_t flops_per_token = 6 * N + (size_t)6 * L * C * T;
    size_t flops_per_step = flops_per_token * num_tokens;

    float flops_achieved = (float)flops_per_step * (1.0f / dt);
    float flops_promised = get_flops_promised(deviceProp.name, PRECISION_MODE) * 1e12f;
    if (flops_promised < 0)
    {
        return -1.f;
    }
    float mfu = flops_achieved / flops_promised;
    return mfu;
}

// Release model-owned GPU and CPU memory when the run ends.
// Freeing a buffer releases its storage; it does not delete a checkpoint file.
void gpt2_free(GPT2 *model)
{
    cudaFreeCheck(&model->params_memory);
    cudaFreeCheck(&model->grads_memory);
    cudaFreeCheck(&model->m_memory);
    cudaFreeCheck(&model->v_memory);
    cudaFreeCheck(&model->master_weights);
    cudaFreeCheck(&model->acts_memory);
    cudaFreeCheck(&model->inputs);
    cudaFreeCheck(&model->targets);
    cudaFreeCheck(&model->accumulated_mean_loss);
    cudaCheck(cudaFreeHost(model->cpu_losses));
    free(model->workload_indices);
    free(model->bucket_info);

    cudaFreeCheck(&model->adapter_params_mem);
    cudaFreeCheck(&model->adapter_grads_mem);
    cudaFreeCheck(&model->adapter_acts_mem);
}

// Create the CUDA stream and cuBLAS handles used by the GPU operations.
// TF32 can trade some multiplication precision for speed on supported GPUs.
void common_start(bool override_enable_tf32 = true, bool print_device_info = true)
{

    cudaCheck(cudaGetDeviceProperties(&deviceProp, multi_gpu_config.local_device_idx));
    if (print_device_info)
    {
        printf("[System]\n");
        printf("Device %d: %s\n", multi_gpu_config.local_device_idx, deviceProp.name);
    }

    cudaCheck(cudaStreamCreate(&main_stream));
    nvtxNameCudaStreamA(main_stream, "main stream");

    cublasCheck(cublasLtCreate(&cublaslt_handle));
    cudaCheck(cudaMalloc(&cublaslt_workspace, cublaslt_workspace_size));

    bool enable_tf32 = PRECISION_MODE == PRECISION_FP32 && deviceProp.major >= 8 && override_enable_tf32;
    cublas_compute = enable_tf32 ? CUBLAS_COMPUTE_32F_FAST_TF32 : CUBLAS_COMPUTE_32F;

#ifdef ENABLE_CUDNN
    create_cudnn();
#endif
}

// Destroy the shared GPU handles and workspace after model cleanup.
void common_free(GPT2 &model)
{
    cudaCheck(cudaStreamDestroy(main_stream));
    cudaCheck(cudaFree(cublaslt_workspace));
    cublasCheck(cublasLtDestroy(cublaslt_handle));
#ifdef ENABLE_CUDNN
    destroy_cudnn();
#endif
}

// Save the current step, data position and optimizer history for resuming.
// This inherited resume format is not a guarantee of correct adapter-state handling.
void save_state(const char *filename, int step, GPT2 *model, DataLoader *loader)
{
    printf("Writing state to %s\n", filename);
    FILE *state_file = fopenCheck(filename, "wb");
    int state_header[256];
    memset(state_header, 0, sizeof(state_header));

    state_header[0] = 20240527;
    state_header[1] = 1;
    state_header[2] = multi_gpu_config.num_processes;
    state_header[3] = multi_gpu_config.process_rank;
    state_header[4] = model->use_master_weights;
    state_header[5] = loader->should_shuffle;

    state_header[10] = step;

    *((unsigned long long *)&state_header[20]) = model->rng_state;
    *((unsigned long long *)&state_header[22]) = model->rng_state_last_update;

    *((size_t *)&state_header[30]) = loader->current_shard_idx;
    *((size_t *)&state_header[32]) = loader->current_sample_idx;
    fwriteCheck(state_header, sizeof(int), 256, state_file);

    size_t shard_num_parameters = multi_gpu_config.shard_num_parameters;
    device_to_file(state_file, model->m_memory, shard_num_parameters * sizeof(float), IO_BUF_SIZE, main_stream);
    device_to_file(state_file, model->v_memory, shard_num_parameters * sizeof(float), IO_BUF_SIZE, main_stream);
    if (model->use_master_weights)
    {
        device_to_file(state_file, model->master_weights, shard_num_parameters * sizeof(float), IO_BUF_SIZE, main_stream);
    }

    if (loader->should_shuffle)
    {
        fwriteCheck(&loader->glob_result.gl_pathc, sizeof(size_t), 1, state_file);
        fwriteCheck(loader->shard_indices, sizeof(int), loader->glob_result.gl_pathc, state_file);
        fwriteCheck(&loader->shard_num_samples, sizeof(size_t), 1, state_file);
        fwriteCheck(loader->intra_shard_indices, sizeof(int), loader->shard_num_samples, state_file);
        fwriteCheck(&loader->shuffle_rng, sizeof(mt19937_state), 1, state_file);
    }
    fcloseCheck(state_file);
}

// Restore the saved run position and optimizer state.
// Loss-report references are process-local and start fresh after this reload.
void load_state(int *step, GPT2 *model, DataLoader *loader, const char *filename)
{
    FILE *state_file = fopenCheck(filename, "rb");
    int state_header[256];
    freadCheck(state_header, sizeof(int), 256, state_file);
    assert(state_header[0] == 20240527);
    assert(state_header[1] == 1);
    assert(state_header[2] == multi_gpu_config.num_processes);
    assert(state_header[3] == multi_gpu_config.process_rank);
    int use_master_weights = state_header[4];
    int should_shuffle = state_header[5];
    *step = state_header[10];
    model->rng_state = *((unsigned long long *)&state_header[20]);
    model->rng_state_last_update = *((unsigned long long *)&state_header[22]);
    size_t current_shard_idx = *((size_t *)&state_header[30]);
    size_t current_sample_idx = *((size_t *)&state_header[32]);

    size_t shard_num_parameters = multi_gpu_config.shard_num_parameters;
    if (use_master_weights == 1 && !model->use_master_weights)
    {
        printf0("Warning: Master weights are present in state, but not enabled for current run.");
    }
    else if (use_master_weights == 0 && model->use_master_weights)
    {
        printf0("Error: Master weights requested, but not present in state file.");
        exit(EXIT_FAILURE);
    }

    model->init_state = false;
    assert(model->m_memory != nullptr);
    assert(model->v_memory != nullptr);
    file_to_device(model->m_memory, state_file, shard_num_parameters * sizeof(float), IO_BUF_SIZE, main_stream);
    file_to_device(model->v_memory, state_file, shard_num_parameters * sizeof(float), IO_BUF_SIZE, main_stream);
    if (model->use_master_weights)
    {
        assert(model->master_weights != nullptr);
        file_to_device(model->master_weights, state_file, shard_num_parameters * sizeof(float), IO_BUF_SIZE, main_stream);

        model->rng_state = model->rng_state_last_update;
        gpt2_update(model, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0, &multi_gpu_config,  true);
        model->rng_state = *((unsigned long long *)&state_header[20]);
    }

    loader->should_shuffle = should_shuffle;
    if (should_shuffle == 1)
    {

        size_t glob_result_gl_pathc;
        freadCheck(&glob_result_gl_pathc, sizeof(size_t), 1, state_file);
        assert(glob_result_gl_pathc == loader->glob_result.gl_pathc);

        loader->shard_indices = (int *)mallocCheck(loader->glob_result.gl_pathc * sizeof(int));
        freadCheck(loader->shard_indices, sizeof(int), loader->glob_result.gl_pathc, state_file);

        size_t shard_num_samples;
        freadCheck(&shard_num_samples, sizeof(size_t), 1, state_file);
        assert(shard_num_samples == loader->shard_num_samples);

        loader->intra_shard_indices = (int *)mallocCheck(loader->shard_num_samples * sizeof(int));
        freadCheck(loader->intra_shard_indices, sizeof(int), loader->shard_num_samples, state_file);

        freadCheck(&loader->shuffle_rng, sizeof(mt19937_state), 1, state_file);
    }
    dataloader_resume(loader, current_shard_idx, current_sample_idx);

    fcloseCheck(state_file);
}
// Write the adapter-only header and its four parameter groups.
// The header stores B,L,C,r,T; the payload order is down_w,down_b,up_w,up_b.
void save_adapter(const char *filename, GPT2 *model, int B, int L, int C, int r, int T)
{
    printf0("Writing adapter parameters to %s\n", filename);
    // Open the adapter checkpoint and stop with an error if the file cannot be created.
    FILE *adapter_file = fopenCheck(filename, "w");
    // Start the five-integer header before writing the packed parameter arrays.
    fwriteCheck(&B, sizeof(int), 1, adapter_file);
    fwriteCheck(&L, sizeof(int), 1, adapter_file);
    fwriteCheck(&C, sizeof(int), 1, adapter_file);
    fwriteCheck(&r, sizeof(int), 1, adapter_file);
    fwriteCheck(&T, sizeof(int), 1, adapter_file);
    size_t nelements = (size_t)L * C * r;
    device_to_file(adapter_file, model->adapter.down_w, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);
    nelements = (size_t)L * r;
    device_to_file(adapter_file, model->adapter.down_b, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);
    nelements = (size_t)L * r * C;
    device_to_file(adapter_file, model->adapter.up_w, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);
    nelements = (size_t)L * C;
    device_to_file(adapter_file, model->adapter.up_b, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);

    fcloseCheck(adapter_file);
}

// Read an adapter checkpoint into already allocated GPU arrays.
// The caller must supply compatible sizes; this inherited loader has limited checks.
void load_adapter(const char *filename, GPT2 *model, int *B, int *L, int *C, int *r, int *T)
{
    FILE *adapter_file = fopenCheck(filename, "r");
    freadCheck(B, sizeof(int), 1, adapter_file);
    freadCheck(L, sizeof(int), 1, adapter_file);
    freadCheck(C, sizeof(int), 1, adapter_file);
    freadCheck(r, sizeof(int), 1, adapter_file);
    freadCheck(T, sizeof(int), 1, adapter_file);
    model->adapter_dim = *r;
    size_t nelements = (size_t)(*L) * (*C) * (*r);

    file_to_device(model->adapter.down_w, adapter_file, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);
    nelements = (size_t)(*L) * (*r);
    file_to_device(model->adapter.down_b, adapter_file, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);
    nelements = (size_t)(*L) * (*r) * (*C);
    file_to_device(model->adapter.up_w, adapter_file, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);
    nelements = (size_t)(*L) * (*C);
    file_to_device(model->adapter.up_b, adapter_file, nelements * sizeof(floatX), IO_BUF_SIZE, main_stream);

    cudaCheck(cudaStreamSynchronize(main_stream));

    fcloseCheck(adapter_file);
}
// Save a coordinated snapshot of model, adapter and run state.
// A completed marker helps the resume code distinguish finished snapshots.
void write_checkpoint(const char *output_log_dir, int step, GPT2 *model, DataLoader *train_loader, MultiGpuConfig *multi_gpu_config)
{

    printf0("Writing checkpoint at step %d\n", step);
    int rank = multi_gpu_config->process_rank;

    if (rank == 0)
    {
        snprintf(filename_buffer, sizeof(filename_buffer), "%s/model_%08d.bin", output_log_dir, step);
        gpt2_write_to_checkpoint(model, filename_buffer);
    }

    snprintf(filename_buffer, sizeof(filename_buffer), "%s/state_%08d_%05d.bin", output_log_dir, step, rank);
    save_state(filename_buffer, step, model, train_loader);

    multi_gpu_barrier(multi_gpu_config);
    if (rank == 0)
    {
        snprintf(filename_buffer, sizeof(filename_buffer), "%s/DONE_%08d", output_log_dir, step);
        FILE *done_file = fopenCheck(filename_buffer, "w");
        fcloseCheck(done_file);
    }
    if (rank == 0 && model->use_adapters)
    {
        snprintf(filename_buffer, sizeof(filename_buffer), "%s/adapter_params_%08d.bin", output_log_dir, step);
        size_t L = model->config.num_layers;
        size_t C = model->config.channels;
        size_t r = model->adapter_dim;
        save_adapter(filename_buffer, model, model->batch_size, L, C, r, model->seq_len);
    }
}

// Remove an old snapshot only when checkpoint-retention options request it.
// A separate output directory keeps an experiment away from earlier results.
void delete_checkpoint(const char *output_log_dir, int step, MultiGpuConfig *multi_gpu_config)
{

    printf0("Deleting checkpoint at step %d\n", step);
    int rank = multi_gpu_config->process_rank;
    if (rank == 0)
    {
        snprintf(filename_buffer, sizeof(filename_buffer), "%s/model_%08d.bin", output_log_dir, step);
        remove(filename_buffer);
    }
    snprintf(filename_buffer, sizeof(filename_buffer), "%s/state_%08d_%05d.bin", output_log_dir, step, rank);
    remove(filename_buffer);
    if (rank == 0)
    {
        snprintf(filename_buffer, sizeof(filename_buffer), "%s/DONE_%08d", output_log_dir, step);
        remove(filename_buffer);
    }
}

// Store one reference for each kind of loss, so training and validation stay separate.
// Step -1 means no valid measurement has set the reference yet.
struct LossReportReference
{
    float loss = 0.0f;
    int step = -1;
};

// Describe one measured loss in plain language, then show its size relative to the first.
// Double arithmetic keeps the ratio safe even when float losses are very far apart.
static void print_loss_report(const char *phase, int step, int total_steps,
                              float loss, LossReportReference *reference)
{
    // An invalid loss should stay visible instead of silently becoming a reference.
    if (!isfinite(loss) || loss < 0.0f)
    {
        printf0("Step %d of %d had %s loss %.6f nats/token; relative loss: n/a (invalid measurement).\n",
                step, total_steps, phase, loss);
        return;
    }
    // Capture the first valid value in this process, including a fresh baseline after resume.
    if (reference->step < 0)
    {
        reference->loss = loss;
        reference->step = step;
    }
    printf0("Step %d of %d had %s loss %.6f nats/token; ", step, total_steps, phase, loss);
    // A zero reference has no usable denominator, even when the current loss is also zero.
    if (reference->loss == 0.0f)
    {
        printf0("loss relative to first %s: n/a (reference at step %d is zero).\n",
                phase, reference->step);
        return;
    }
    const double relative_percent = 100.0 * (double)loss / (double)reference->loss;
    printf0("loss relative to first %s: %.2f%% (step %d reference: %.6f).\n",
            phase, relative_percent, reference->step, reference->loss);
}

#ifndef TESTING

// Print the accepted command-line settings when an argument is invalid.
// Every setting below expects a value after its flag.
void error_usage()
{
    fprintf(stderr, "Usage:   ./test_adapter_copy [options]\n");
    fprintf(stderr, "Options:\n");

    fprintf(stderr, "  -i <string> train data filename pattern (default = dev/data/tinyshakespeare/tiny_shakespeare_train.bin)\n");
    fprintf(stderr, "  -j <string> val data filename pattern (default = dev/data/tinyshakespeare/tiny_shakespeare_val.bin)\n");
    fprintf(stderr, "  -e <string> input .bin filename or descriptor, see code comments as docs. (default = gpt2_124M_bf16.bin)\n");
    fprintf(stderr, "  -o <string> output log dir (default = NULL, no logging)\n");
    fprintf(stderr, "  -lg <int>   log gpu info every x steps (default = -1; disabled)\n");
    fprintf(stderr, "  -n <int>    write optimization checkpoints every how many steps? (default 0, don't)\n");
    fprintf(stderr, "  -nk <int>   max number of checkpoints to keep in the directory, removing old ones (0 = disable, default)\n");
    fprintf(stderr, "  -nm <int>   every how many step checkpoints are considered major? major checkpoints never get deleted.\n");
    fprintf(stderr, "  -y <int>    resume optimization found inside output log dir? (0=restart/overwrite, 1=resume/append)\n");

    fprintf(stderr, "  -b <int>    (per-GPU, micro) batch size B (default = 4)\n");
    fprintf(stderr, "  -t <int>    sequence length T (default = 1024)\n");
    fprintf(stderr, "  -d <int>    total desired batch size (default = B * T * num_processes, i.e. no grad accumulation\n");

    fprintf(stderr, "  -x <int>    max_steps of optimization to run (-1 (default) = disable, run 1 epoch)\n");

    fprintf(stderr, "  -k <string> learning rate scheduler (default = cosine)\n");
    fprintf(stderr, "  -l <float>  learning rate (default = 3e-4f)\n");
    fprintf(stderr, "  -u <int>    learning rate warmup iterations (default = 0, no warmup)\n");
    fprintf(stderr, "  -q <float>  learning rate decay: final fraction, at end of training (default = 1.0 (no decay))\n");
    fprintf(stderr, "  -c <float>  weight decay (default = 0.0f)\n");
    fprintf(stderr, "  -sl <float> outlier stability: skip update if loss goes above this in zscore (0.0f=off)\n");
    fprintf(stderr, "  -sg <float> outlier stability: skip update if grad_norm goes above this in zscore (0.0f=off)\n");

    fprintf(stderr, "  -v <int>    val_loss_every, how often we evaluate val loss (default = 20)\n");
    fprintf(stderr, "  -m <int>    val_max_steps, up to how many val batches to estimate val loss? (default = 20)\n");
    fprintf(stderr, "  -s <int>    sample_every, how often we inference the model (default = 20)\n");
    fprintf(stderr, "  -g <int>    genT, how many steps of inference we do (default = 64)\n");
    fprintf(stderr, "  -h <int>    hellaswag eval run? (default = 0)\n");

    fprintf(stderr, "  -a <int>    overfit a single batch? 0/1. useful for debugging\n");

    fprintf(stderr, "  -f <int>    enable_tf32 override (default: 1, set to 0 to disable tf32)\n");
    fprintf(stderr, "  -w <int>    keep f32 copy of weights for the optimizer? (default: 1)\n");
    fprintf(stderr, "  -ge <int>   gelu fusion: 0=none, 1=forward, 2=forward+backward (default: 2 for >=SM90, 0 for older GPUs)\n");

    fprintf(stderr, "  -z <int>    zero_stage, Zero Optimization Stage, 0,1,2,3 (default = 0)\n");
    fprintf(stderr, "  -r <int>    recompute: less memory but less speed. (default = 1), 0|1|2 = none,gelu,gelu+ln\n");

    fprintf(stderr, "  -pn <int>    num_processes (default = 1)\n");
    fprintf(stderr, "  -pr <int>    process_rank (default = 0)\n");
    fprintf(stderr, "  -pg <int>    gpus_per_node (default = 8)\n");
    fprintf(stderr, "  -pm <string> nccl_init_method: tcp,fs,mpi (default = mpi)\n");
    fprintf(stderr, "  -ps <string> server_ip - used only when nccl_init_method is tcp (default = -1)\n");
    fprintf(stderr, "  -pp <string> fs_path - used only when nccl_init_method is fs (default = /tmp)\n");

    fprintf(stderr, "  -Ar <int>   use adapters 0/1 (default 0)\n");
    fprintf(stderr, "  -Ad <int>   adapter rank (default 32)\n");
    fprintf(stderr, "  -Af <int>   freeze base weights if adapters (0/1 default 1)\n");
    exit(EXIT_FAILURE);
}

// Read run settings, load the model, then alternate measurement and learning.
// The final loop visit measures the model and exits before another update.
int main(int argc, char *argv[])
{

    const char *train_data_pattern = "dev/data/tinyshakespeare/tiny_shakespeare_train.bin";
    const char *val_data_pattern = "dev/data/tinyshakespeare/tiny_shakespeare_val.bin";
    const char *load_filename = "log124M/model_00019552.bin";
    // Choose how the learning rate changes as the run progresses.
    const char *lr_scheduler_type = "cosine";
    const char *output_log_dir = NULL;
    int checkpoint_every = 0;
    int checkpoints_keep = 0;
    int major_checkpoint_every = 0;
    int resume = 0;
    int B = 4;
    int T = 1024;
    int total_batch_size = -1;
    // Set the update-size multiplier; larger values move weights more per step.
    float learning_rate = 3e-4f;
    int log_gpu_every = -1;
    int warmup_iterations = 0;
    float final_learning_rate_frac = 1.0f;
    float weight_decay = 0.0f;
    float skip_update_lossz = 0.0f;
    float skip_update_gradz = 0.0f;
    int val_loss_every = 20;
    int val_max_steps = 20;
    int sample_every = 20;
    int genT = 64;
    // Optionally repeat one batch as a debugging exercise rather than learning varied text.
    int overfit_single_batch = 0;
    // A nonnegative -x limits optimizer-loop iterations; zero runs measurements only.
    int max_steps = -1;
    int override_enable_tf32 = 1;
    int use_master_weights = 1;
    int gelu_fusion = -1;
    int recompute = 1;
    int zero_stage = 0;
    int hellaswag_eval = 0;

    int num_processes = 1;
    int process_rank = 0;
    int gpus_per_node = 8;
    char nccl_init_method[256] = "mpi";
    char server_ip[256] = "";
    char fs_path[256] = "";

    int use_adapters = 0;
    // Use a 32-feature bottleneck unless -Ad requests another width.
    int adapter_dim = 32;
    int adapter_freeze = 1;
    bool init_from_file = false;
    // Leave adapter loading disabled until -Ae supplies a checkpoint path.
    char *adapter_load_filename = nullptr;

    // Read one flag and one value at a time, such as -Ad 32 for adapter width.
    for (int i = 1; i < argc; i += 2)
    {
        if (i + 1 >= argc)
        {
            error_usage();
        }
        if (argv[i][0] != '-')
        {
            error_usage();
        }
        if (!(strlen(argv[i]) == 2 || strlen(argv[i]) == 3))
        {
            error_usage();
        }

        if (argv[i][1] == 'i')
        {
            train_data_pattern = argv[i + 1];
        }
        else if (argv[i][1] == 'j')
        {
            val_data_pattern = argv[i + 1];
        }
        else if (argv[i][1] == 'e')
        {
            load_filename = argv[i + 1];
        }
        else if (argv[i][1] == 'o')
        {
            output_log_dir = argv[i + 1];
        }
        else if (argv[i][1] == 'n' && argv[i][2] == '\0')
        {
            checkpoint_every = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'y')
        {
            resume = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'b')
        {
            B = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 't')
        {
            T = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'd')
        {
            total_batch_size = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'l' && argv[i][2] == '\0')
        {
            learning_rate = atof(argv[i + 1]);
        }
        else if (argv[i][1] == 'l' && argv[i][2] == 'g')
        {
            log_gpu_every = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'u')
        {
            warmup_iterations = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'q')
        {
            final_learning_rate_frac = atof(argv[i + 1]);
        }
        else if (argv[i][1] == 'c')
        {
            weight_decay = atof(argv[i + 1]);
        }
        else if (argv[i][1] == 'x')
        {
            max_steps = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'v')
        {
            val_loss_every = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'm')
        {
            val_max_steps = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 's' && argv[i][2] == '\0')
        {
            sample_every = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'g' && argv[i][2] == 'e')
        {
            gelu_fusion = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'g')
        {
            genT = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'a')
        {
            overfit_single_batch = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'f')
        {
            override_enable_tf32 = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'w')
        {
            use_master_weights = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'z')
        {
            zero_stage = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'r')
        {
            recompute = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'h')
        {
            hellaswag_eval = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'k')
        {
            lr_scheduler_type = argv[i + 1];
        }
        else if (argv[i][1] == 'p' && argv[i][2] == 'i')
        {
            strcpy(nccl_init_method, argv[i + 1]);
        }
        else if (argv[i][1] == 'p' && argv[i][2] == 'f')
        {
            strcpy(fs_path, argv[i + 1]);
        }
        else if (argv[i][1] == 'p' && argv[i][2] == 's')
        {
            strcpy(server_ip, argv[i + 1]);
        }
        else if (argv[i][1] == 'p' && argv[i][2] == 'n')
        {
            num_processes = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'p' && argv[i][2] == 'r')
        {
            process_rank = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'p' && argv[i][2] == 'g')
        {
            gpus_per_node = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 's' && argv[i][2] == 'l')
        {
            skip_update_lossz = atof(argv[i + 1]);
        }
        else if (argv[i][1] == 's' && argv[i][2] == 'g')
        {
            skip_update_gradz = atof(argv[i + 1]);
        }
        else if (argv[i][1] == 'n' && argv[i][2] == 'k')
        {
            checkpoints_keep = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'n' && argv[i][2] == 'm')
        {
            major_checkpoint_every = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'A' && argv[i][2] == 'r')
        {
            use_adapters = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'A' && argv[i][2] == 'd')
        {
            adapter_dim = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'A' && argv[i][2] == 'f')
        {
            adapter_freeze = atoi(argv[i + 1]);
        }
        else if (argv[i][1] == 'A' && argv[i][2] == 'e')
        {
            adapter_load_filename = argv[i + 1];
            init_from_file = true;
        }
        else
        {
            error_usage();
        }
    }

    multi_gpu_config = multi_gpu_config_init(num_processes, process_rank, gpus_per_node, server_ip, fs_path, nccl_init_method);
    common_start(override_enable_tf32, false);

    assert(warmup_iterations >= 0);
    if (output_log_dir != NULL)
    {
        assert(strlen(output_log_dir) < 400);
    }
    int tokens_per_fwdbwd = B * T * multi_gpu_config.num_processes;

    // When no total batch is supplied, use one micro-batch from each GPU per update.
    if (total_batch_size == -1)
    {
        total_batch_size = tokens_per_fwdbwd;
    }

    if (gelu_fusion == -1)
    {
        gelu_fusion = 0;
    }

    assert(total_batch_size % tokens_per_fwdbwd == 0);
    // Split a large requested batch across smaller GPU passes before an update.
    int grad_accum_steps = total_batch_size / tokens_per_fwdbwd;

    // Use the same small batch repeatedly when the single-batch debug option is enabled.
    if (overfit_single_batch == 1)
    {
        train_data_pattern = val_data_pattern;
    }
    printf0("+-----------------------+----------------------------------------------------+\n");
    printf0("| Parameter             | Value                                              |\n");
    printf0("+-----------------------+----------------------------------------------------+\n");
    printf0("| train data pattern    | %-50s |\n", train_data_pattern);
    printf0("| val data pattern      | %-50s |\n", val_data_pattern);
    printf0("| output log dir        | %-50s |\n", output_log_dir == NULL ? "NULL" : output_log_dir);
    printf0("| checkpoint_every      | %-50d |\n", checkpoint_every);
    printf0("| resume                | %-50d |\n", resume);
    printf0("| micro batch size B    | %-50d |\n", B);
    printf0("| sequence length T     | %-50d |\n", T);
    printf0("| total batch size      | %-50d |\n", total_batch_size);
    printf0("| LR scheduler          | %-50s |\n", lr_scheduler_type);
    printf0("| learning rate (LR)    | %-50e |\n", learning_rate);
    printf0("| warmup iterations     | %-50d |\n", warmup_iterations);
    printf0("| final LR fraction     | %-50e |\n", final_learning_rate_frac);
    printf0("| weight decay          | %-50e |\n", weight_decay);
    printf0("| skip update lossz     | %-50f |\n", skip_update_lossz);
    printf0("| skip update gradz     | %-50f |\n", skip_update_gradz);
    printf0("| max_steps             | %-50d |\n", max_steps);
    printf0("| val_loss_every        | %-50d |\n", val_loss_every);
    printf0("| val_max_steps         | %-50d |\n", val_max_steps);
    printf0("| sample_every          | %-50d |\n", sample_every);
    printf0("| genT                  | %-50d |\n", genT);
    printf0("| overfit_single_batch  | %-50d |\n", overfit_single_batch);
    printf0("| use_master_weights    | %-50s |\n", use_master_weights ? "enabled" : "disabled");
    printf0("| gelu_fusion           | %-50d |\n", gelu_fusion);
    printf0("| recompute             | %-50d |\n", recompute);
    printf0("+-----------------------+----------------------------------------------------+\n");
    const char *precision_str = (PRECISION_MODE == PRECISION_FP32)
                                    ? (cublas_compute == CUBLAS_COMPUTE_32F_FAST_TF32 ? "TF32" : "FP32")
                                    : (PRECISION_MODE == PRECISION_FP16 ? "FP16" : "BF16");
    printf0("| device                | %-50s |\n", deviceProp.name);
    printf0("| peak TFlops           | %-50.1f |\n", get_flops_promised(deviceProp.name, PRECISION_MODE));
    printf0("| precision             | %-50s |\n", precision_str);
    printf0("+-----------------------+----------------------------------------------------+\n");

    int resuming = 0;

    int resume_max_step = find_max_step(output_log_dir);
    if (resume == 1)
    {
        assert(output_log_dir != NULL);
        if (resume_max_step != -1)
        {
            resuming = 1;
            snprintf(filename_buffer, sizeof(filename_buffer), "%s/model_%08d.bin", output_log_dir, resume_max_step);
        }
    }

    GPT2 model;
    gpt2_init_common(&model);
    if (resuming == 1)
    {

        bool weight_init = !use_master_weights;
        gpt2_build_from_checkpoint(&model, filename_buffer, weight_init);
    }
    else if (ends_with_bin(load_filename))
    {
        printf0("building model from .bin file %s\n", load_filename);

        gpt2_build_from_checkpoint(&model, load_filename);
    }
    else
    {

        gpt_build_from_descriptor(&model, load_filename);
    }

    // Apply the adapter settings after loading the base model resets its defaults.
    model.use_adapters = use_adapters;
    model.adapter_dim = adapter_dim;
    model.freeze_base = adapter_freeze;

    model.use_master_weights = use_master_weights;
    model.gelu_fusion = gelu_fusion;
    model.recompute = recompute;
    printf0("| weight init method    | %-50s |\n", resuming == 1 ? "intermediate checkpoint" : load_filename);
    printf0("| max_sequence_length T | %-50d |\n", model.config.max_seq_len);
    printf0("| vocab_size V          | %-50d |\n", model.config.vocab_size);
    printf0("| padded_vocab_size Vp  | %-50d |\n", model.config.padded_vocab_size);
    printf0("| num_layers L          | %-50d |\n", model.config.num_layers);
    printf0("| num_heads NH          | %-50d |\n", model.config.num_heads);
    printf0("| channels C            | %-50d |\n", model.config.channels);
    printf0("| num_parameters        | %-50zu |\n", model.num_parameters);
    printf0("+-----------------------+----------------------------------------------------+\n");

    int permute_train_loader = (overfit_single_batch == 1) ? 0 : 1;
    DataLoader train_loader, val_loader;
    dataloader_init(&train_loader, train_data_pattern, B, T, multi_gpu_config.process_rank, multi_gpu_config.num_processes, permute_train_loader);
    dataloader_init(&val_loader, val_data_pattern, B, T, multi_gpu_config.process_rank, multi_gpu_config.num_processes, 0);

    int train_num_batches = max_steps;

    if (train_num_batches == -1)
    {

        size_t ntok = train_loader.num_tokens;

        train_num_batches = ntok / total_batch_size;
    }

    int val_num_batches = val_max_steps;
    if (val_num_batches == -1)
    {

        size_t ntok = val_loader.num_tokens;

        val_num_batches = ntok / tokens_per_fwdbwd;
    }
    printf0("| train_num_batches     | %-50d |\n", train_num_batches);
    printf0("| val_num_batches       | %-50d |\n", val_num_batches);
    printf0("+-----------------------+----------------------------------------------------+\n");

    EvalLoader eval_loader;
    const char *hellaswag_path = "dev/data/hellaswag/hellaswag_val.bin";
    const bool hellaswag_available = access(hellaswag_path, F_OK) == 0;
    const bool run_hellaswag = hellaswag_eval && hellaswag_available;
    if (run_hellaswag)
    {
        evalloader_init(&eval_loader, hellaswag_path, B, T, multi_gpu_config.process_rank, multi_gpu_config.num_processes);
    }
    printf0("| run hellaswag         | %-50s |\n", run_hellaswag ? "yes" : "no");
    printf0("+-----------------------+----------------------------------------------------+\n");

    set_zero_configs(&multi_gpu_config, zero_stage, model.num_parameters);
    printf0("| num_processes         | %-50d |\n", multi_gpu_config.num_processes);
    printf0("| zero_stage            | %-50d |\n", multi_gpu_config.zero_stage);
    printf0("+-----------------------+----------------------------------------------------+\n");

    if (!hellaswag_available)
    {
        printf0("HellaSwag eval not found at %s, skipping its evaluation\n", hellaswag_path);
        printf0("You can run `python dev/data/hellaswag.py` to export and use it with `-h 1`.\n");
    }

    printf0("num_parameters: %zu => bytes: %zu\n", model.num_parameters, model.num_parameters_bytes);
    printf0("allocated %d MiB for model parameters\n", (int)round(model.num_parameters_bytes / (1024 * 1024)));

    printf0("batch_size B=%d * seq_len T=%d * num_processes=%d and total_batch_size=%d\n",
            B, T, multi_gpu_config.num_processes, total_batch_size);
    printf0("=> setting grad_accum_steps=%d\n", grad_accum_steps);

    if (multi_gpu_config.process_rank == 0)
    {
        create_dir_if_not_exists(output_log_dir);
    }
    Logger logger;
    logger_init(&logger, output_log_dir, multi_gpu_config.process_rank, resume);

    Tokenizer tokenizer;
    tokenizer_init(&tokenizer, "gpt2_tokenizer.bin");

    LearningRateScheduler lr_scheduler;
    lr_scheduler_init(&lr_scheduler, lr_scheduler_type, learning_rate,
                      warmup_iterations, train_num_batches, final_learning_rate_frac);

    int *gen_tokens = (int *)mallocCheck(B * T * sizeof(int));
    floatX *cpu_logits_raw = (floatX *)mallocCheck(model.config.vocab_size * sizeof(floatX));
    float *cpu_logits = (float *)mallocCheck(model.config.vocab_size * sizeof(float));

    // Count completed optimizer-loop iterations; a resumed checkpoint can replace this starting value.
    int step = 0;
    gpt2_allocate_state(&model, B, T);
    int adapter_load_B = 0, adapter_load_L = 0, adapter_load_C = 0, adapter_load_r = 0, adapter_load_T = 0;
    // Allocate the optional adapter branch after the base model's working state exists.
    if (model.use_adapters)
    {
        allocate_adapters(&model, B, T);
        if(init_from_file)
        {
            if (adapter_load_filename == nullptr)
            {
                fprintf(stderr, "Error: adapter_load_filename is null but init_from_file is true\n");
                exit(EXIT_FAILURE);
            }
            load_adapter(adapter_load_filename, &model, &adapter_load_B, &adapter_load_L, &adapter_load_C, &adapter_load_r, &adapter_load_T);
            printf0("loaded adapters from %s, B=%d, L=%d, C=%d, r=%d, T=%d\n", adapter_load_filename, adapter_load_B, adapter_load_L, adapter_load_C, adapter_load_r, adapter_load_T);
        }
    }
    if (resuming == 1)
    {
        snprintf(filename_buffer, sizeof(filename_buffer), "%s/state_%08d_%05d.bin", output_log_dir, resume_max_step, multi_gpu_config.process_rank);
        load_state(&step, &model, &train_loader, filename_buffer);
    }

    OutlierDetector loss_outlier_detector, grad_norm_outlier_detector;
    init_detector(&loss_outlier_detector);
    init_detector(&grad_norm_outlier_detector);

    if (T < model.config.max_seq_len)
    {
        printf0("!!!!!!!!\n");
        printf0("WARNING:\n");
        printf0("- The training sequence length is: T=%d (set with -t)\n", T);
        printf0("- The model's max sequence length is: max_seq_len=%d\n", model.config.max_seq_len);
        printf0("You are attempting to train with a sequence length shorter than the model's max.\n");
        printf0("This will lead to unused parameters in the wpe position embedding weights.\n");
        printf0("If you know what you're doing you can ignore this warning.\n");
        printf0("If you're like ???, you are most likely misconfiguring your training run.\n");
        printf0("---> HINT: If you're training GPT-2 use -t 1024. If GPT-3, use -t 2048.\n");
        printf0("!!!!!!!!\n");
    }

    assert(T <= model.config.max_seq_len);

    cudaEvent_t start, end;
    cudaCheck(cudaEventCreate(&start));
    cudaCheck(cudaEventCreate(&end));
    cudaCheck(cudaProfilerStart());
    double total_sum_iteration_time_s = 0.0;
    // Smooth speed readings over steps so brief timing swings are less distracting.
    float ema_tokens_per_second = 0.0f;

    printf0("Planned training steps: %d\n", train_num_batches);

    // References affect display only; the model and optimizer never read them.
    LossReportReference validation_reference;
    LossReportReference training_reference;
    printf0("Starting at step %d; validation reports measure completed loop steps.\n", step);
    printf0("Relative loss = 100 * current loss / first measured loss of that type.\n");
    printf0("Lower is better; this percentage is not token error rate or accuracy.\n");
    if (model.use_adapters)
        printf0("Teaching copy: inherited adapter training defects remain; see the top comment.\n");

    // The extra final visit measures the last result; it does not run another update.
    for (; step <= train_num_batches; step++)
    {
        NvtxRange step_range("Train step", step);

        int last_step = step == train_num_batches;

        // Measure validation before training this iteration and once again at the very end.
        if (step % val_loss_every == 0 || last_step)
        {
            NvtxRange validation_range("validation");
            float val_loss = 0.0f;
            // Revisit the same validation prefix so successive reports compare the same text.
            dataloader_reset(&val_loader);
            for (int i = 0; i < val_num_batches; i++)
            {
                dataloader_next_batch(&val_loader);
                // Score a held-out batch and add its mean loss; no weights change during this call.
                val_loss += gpt2_validate(&model, val_loader.inputs, val_loader.targets, B, T);
            }
            // Average equally sized validation batches before combining results across GPUs.
            val_loss /= val_num_batches;
            // Average validation results across GPUs so the printed value describes the whole run.
            val_loss = multi_gpu_cpu_float_sum(val_loss, &multi_gpu_config) / multi_gpu_config.num_processes;
            // Name the completed step and compare against this run's first validation value.
            print_loss_report("validation", step, train_num_batches, val_loss, &validation_reference);
            // Keep raw numeric validation loss in the existing logger for scripts that read it.
            logger_log_val(&logger, step, val_loss);
        }

        if (run_hellaswag &&
            ((step > 0 && step % val_loss_every == 0) || last_step))
        {
            NvtxRange evaluation_range("evaluation");
            float eval_acc_norm = 0.0f;
            evalloader_reset(&eval_loader);
            for (int i = 0; i < eval_loader.num_batches; i++)
            {
                if (i % 10 == 0)
                {
                    printf("evaluating HellaSwag: %d/%d\r", i, eval_loader.num_batches);
                }
                evalloader_next_batch(&eval_loader);
                gpt2_validate(&model, eval_loader.inputs, eval_loader.targets, B, T);
                int correct = evalloader_stat_losses(&eval_loader, model.cpu_losses);
                eval_acc_norm += (float)correct;
            }

            eval_acc_norm = multi_gpu_cpu_float_sum(eval_acc_norm, &multi_gpu_config);
            printf0("HellaSwag: %d/%d = %f\n", (int)eval_acc_norm, eval_loader.num_examples, eval_acc_norm / eval_loader.num_examples);
            logger_log_eval(&logger, step, eval_acc_norm / eval_loader.num_examples);
        }

        if (multi_gpu_config.process_rank == 0 && sample_every > 0 &&
            (step > 0 && (step % sample_every) == 0 || last_step))
        {
            NvtxRange generation_range("generation");
            unsigned long long sample_rng_state = 1337;

            int eot_token = tokenizer.eot_token;
            for (int i = 0; i < B * T; ++i)
            {
                gen_tokens[i] = eot_token;
            }

            printf("generating:\n---\n");
            for (int t = 1; t < genT; t++)
            {
                NvtxRange generation_range("Generation step", t);

                gpt2_forward(&model, gen_tokens, 1, CEIL_DIV(t, min(T, 256)) * min(T, 256));

                floatX *logits = model.acts.output + (t - 1) * model.config.padded_vocab_size;

                cudaCheck(cudaMemcpy(cpu_logits_raw, logits, model.config.vocab_size * sizeof(floatX), cudaMemcpyDeviceToHost));

                for (int i = 0; i < model.config.vocab_size; i++)
                {
                    cpu_logits[i] = (float)cpu_logits_raw[i];
                }

                float coin = random_f32(&sample_rng_state);
                int next_token = sample_softmax(cpu_logits, model.config.vocab_size, coin);
                gen_tokens[t] = next_token;

                if (tokenizer.init_ok)
                {
                    const char *token_str = tokenizer_decode(&tokenizer, next_token);
                    safe_printf(token_str);
                }
                else
                {

                    printf("%d ", next_token);
                }
                fflush(stdout);
            }
            printf("\n---\n");
        }

        if ((checkpoint_every > 0 && output_log_dir != NULL && resuming == 0) &&
            ((step > 0 && step % checkpoint_every == 0) || last_step))
        {

            write_checkpoint(output_log_dir, step, &model, &train_loader, &multi_gpu_config);

            int step_delete = step - checkpoints_keep * checkpoint_every;
            if (checkpoints_keep > 0 && step_delete > 0 &&
                (major_checkpoint_every == 0 || step_delete % major_checkpoint_every != 0))
            {
                delete_checkpoint(output_log_dir, step_delete, &multi_gpu_config);
            }
        }
        resuming = 0;

        // Stop after the final measurements; the following code would otherwise update again.
        if (last_step)
        {
            break;
        }

        // Use the same small batch repeatedly when the single-batch debug option is enabled.
    if (overfit_single_batch == 1)
        {

            dataloader_reset(&train_loader);
        }

        cudaCheck(cudaEventRecord(start));

        // Accumulate several small batches when the full requested batch will not fit at once.
        for (int micro_step = 0; micro_step < grad_accum_steps; micro_step++)
        {

            // Read the next sequence of training tokens and its shifted next-token answers.
            dataloader_next_batch(&train_loader);

            gpt2_forward(&model, train_loader.inputs, B, T);

            gpt2_backward_and_reduce(&model, train_loader.inputs, train_loader.targets, grad_accum_steps, micro_step);
        }
        float zloss = (float)(update_detector(&loss_outlier_detector, (double)model.mean_loss));

        float step_learning_rate = get_learning_rate(&lr_scheduler, step);

        float grad_norm = gpt2_calculate_grad_norm(&model, &multi_gpu_config);
        float zgrad = (float)(update_detector(&grad_norm_outlier_detector, (double)grad_norm));

        if (isfinite(zloss) && skip_update_lossz != 0.0f && zloss > skip_update_lossz)
        {
            printf0("skipping update due to loss z-score of %f\n", zloss);
        }
        else if (isfinite(zgrad) && skip_update_gradz != 0.0f && zgrad > skip_update_gradz)
        {
            printf0("skipping update due to grad z-score of %f\n", zgrad);
        }
        else
        {

            // Limit the overall gradient size before applying the optimizer update.
        float grad_clip = 1.0f;
            // Scale overly large gradients down to the clipping threshold without changing direction.
        float grad_scale = (grad_norm > grad_clip) ? grad_clip / grad_norm : 1.0f;
            gpt2_update(&model, step_learning_rate, 0.9f, 0.95f, 1e-8f, weight_decay, grad_scale, step + 1, &multi_gpu_config);
        }
        cudaCheck(cudaEventRecord(end));
        cudaCheck(cudaEventSynchronize(end));

        float time_elapsed_ms;
        cudaCheck(cudaEventElapsedTime(&time_elapsed_ms, start, end));
        size_t tokens_processed = (size_t)multi_gpu_config.num_processes * B * T * grad_accum_steps;
        float tokens_per_second = tokens_processed / time_elapsed_ms * 1000.0f;
        float bias_corrected_ema_tokens_per_second = tokens_per_second;
        if (step > 0)
        {
            total_sum_iteration_time_s += time_elapsed_ms / 1000.0f;

            ema_tokens_per_second = 0.95f * ema_tokens_per_second + 0.05f * tokens_per_second;
            bias_corrected_ema_tokens_per_second = ema_tokens_per_second / (1.0f - powf(0.95f, step));
        }
        float mfu = gpt2_estimate_mfu(&model, B * T * grad_accum_steps, time_elapsed_ms / 1000.0f);
        // This loss came from the batch evaluated before the just-completed update.
        print_loss_report("training", step + 1, train_num_batches, model.mean_loss, &training_reference);
        printf0("  Step details: gradient norm %.4f | learning rate %.2e | %.2f ms | %.0f tokens/s\n",
                grad_norm, step_learning_rate, time_elapsed_ms, bias_corrected_ema_tokens_per_second);
        // A negative MFU means this GPU has no recognized peak estimate in the lookup table.
        if (isfinite(mfu) && mfu >= 0.0f)
        {
            printf0("  Estimated GPU arithmetic utilization: %.1f%% (%s).\n", 100 * mfu, precision_str);
        }
        else
        {
            printf0("  Estimated GPU arithmetic utilization: unavailable for this GPU.\n");
        }
        if (log_gpu_every > 0 && (step + 1) % log_gpu_every == 0)
        {
            GPUUtilInfo gpu_info = get_gpu_utilization_info();
            printf0("                  compute %2.1f%% | memory: %2.1f%% | fan: %2d%% | %4d MHz / %4d MHz | %3d W / %3d W | %d°C / %d°C | %s\n",
                    gpu_info.gpu_utilization, gpu_info.mem_utilization, gpu_info.fan, gpu_info.clock, gpu_info.max_clock, gpu_info.power / 1000, gpu_info.power_limit / 1000,
                    gpu_info.temperature, gpu_info.temp_slowdown, gpu_info.throttle_reason);
        }
        // Keep the existing machine-readable logger fields; readable reports are printed separately.
        logger_log_train(&logger, step, model.mean_loss, step_learning_rate, grad_norm);

        if (step == 3)
        {
            // End the short profiling window after startup steps have been recorded.
            cudaProfilerStop();
        }
    }

    // The first timed step is warmup, so at least two steps are needed for this average.
    if (train_num_batches > 1)
    {
        printf0("Average step time after warmup: %.3f ms.\n",
                total_sum_iteration_time_s / (train_num_batches - 1) * 1000);
    }
    else
    {
        printf0("Average step time after warmup: unavailable (fewer than two training steps).\n");
    }

    cudaCheck(cudaEventDestroy(end));
    cudaCheck(cudaEventDestroy(start));
    if (run_hellaswag)
    {
        evalloader_free(&eval_loader);
    }
    dataloader_free(&train_loader);
    dataloader_free(&val_loader);
    tokenizer_free(&tokenizer);
    free(cpu_logits_raw);
    free(cpu_logits);
    free(gen_tokens);
    multi_gpu_config_free(&multi_gpu_config);
    gpt2_free(&model);
    common_free(model);
    return 0;
}
#endif
