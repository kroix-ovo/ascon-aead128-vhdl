# Test adapter copy: complete WSL terminal transcript

200-step native CUDA run. Exit status: 0. Validation loss worsened from 5.325532 to 12.772885. The block below contains the entire captured session without omissions.

```text
Windows command invoked:
wsl -d Ubuntu-22.04 -- bash /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/run_test_adapter_copy_training.sh

Run directory: /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw
FP32 run: rank-32 adapters enabled, base weights frozen, 200 steps.
FP32 master copy disabled (-w 0); native adapter defects remain.
test_adapter_copy.cu: OK
build/test_adapter_copy/test_adapter_copy: OK

Executed training command:
stdbuf -oL -eL /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw/test_adapter_copy -e /home/kroix/projects/SAGE_Accelerator/llmc-gpt2/gpt2_124M.bin -i /home/kroix/projects/SAGE_Accelerator/llmc-gpt2/dev/data/tinyshakespeare/tiny_shakespeare_train.bin -j /home/kroix/projects/SAGE_Accelerator/llmc-gpt2/dev/data/tinyshakespeare/tiny_shakespeare_val.bin -o /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw/checkpoints -n 200 -Ar 1 -Ad 32 -Af 1 -b 1 -t 64 -x 200 -v 20 -m 20 -s 0 -r 0 -f 0 -w 0 

Multi-GPU support is disabled. Using a single GPU.
+-----------------------+----------------------------------------------------+
| Parameter             | Value                                              |
+-----------------------+----------------------------------------------------+
| train data pattern    | /home/kroix/projects/SAGE_Accelerator/llmc-gpt2/dev/data/tinyshakespeare/tiny_shakespeare_train.bin |
| val data pattern      | /home/kroix/projects/SAGE_Accelerator/llmc-gpt2/dev/data/tinyshakespeare/tiny_shakespeare_val.bin |
| output log dir        | /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw/checkpoints |
| checkpoint_every      | 200                                                |
| resume                | 0                                                  |
| micro batch size B    | 1                                                  |
| sequence length T     | 64                                                 |
| total batch size      | 64                                                 |
| LR scheduler          | cosine                                             |
| learning rate (LR)    | 3.000000e-04                                       |
| warmup iterations     | 0                                                  |
| final LR fraction     | 1.000000e+00                                       |
| weight decay          | 0.000000e+00                                       |
| skip update lossz     | 0.000000                                           |
| skip update gradz     | 0.000000                                           |
| max_steps             | 200                                                |
| val_loss_every        | 20                                                 |
| val_max_steps         | 20                                                 |
| sample_every          | 0                                                  |
| genT                  | 64                                                 |
| overfit_single_batch  | 0                                                  |
| use_master_weights    | disabled                                           |
| gelu_fusion           | 0                                                  |
| recompute             | 0                                                  |
+-----------------------+----------------------------------------------------+
| device                | NVIDIA GeForce RTX 3080 Laptop GPU                 |
| peak TFlops           | -1.0                                               |
| precision             | FP32                                               |
+-----------------------+----------------------------------------------------+
building model from .bin file /home/kroix/projects/SAGE_Accelerator/llmc-gpt2/gpt2_124M.bin
| weight init method    | /home/kroix/projects/SAGE_Accelerator/llmc-gpt2/gpt2_124M.bin |
| max_sequence_length T | 1024                                               |
| vocab_size V          | 50257                                              |
| padded_vocab_size Vp  | 50304                                              |
| num_layers L          | 12                                                 |
| num_heads NH          | 12                                                 |
| channels C            | 768                                                |
| num_parameters        | 124475904                                          |
+-----------------------+----------------------------------------------------+
| train_num_batches     | 200                                                |
| val_num_batches       | 20                                                 |
+-----------------------+----------------------------------------------------+
| run hellaswag         | no                                                 |
+-----------------------+----------------------------------------------------+
| Zero Optimization is disabled                                              |
| num_processes         | 1                                                  |
| zero_stage            | 0                                                  |
+-----------------------+----------------------------------------------------+
HellaSwag eval not found at dev/data/hellaswag/hellaswag_val.bin, skipping its evaluation
You can run `python dev/data/hellaswag.py` to export and use it with `-h 1`.
num_parameters: 124475904 => bytes: 497903616
allocated 474 MiB for model parameters
batch_size B=1 * seq_len T=64 * num_processes=1 and total_batch_size=64
=> setting grad_accum_steps=1
created directory: /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw/checkpoints
---
WARNING: Failed to open the tokenizer file gpt2_tokenizer.bin
The Tokenizer is a new feature added April 14 2024.
Re-run `python train_gpt2.py` to write it
---
allocating 474 MiB for parameter gradients
allocating 51 MiB for activations
allocating 474 MiB for AdamW optimizer state m
allocating 474 MiB for AdamW optimizer state v
device memory usage: 3089 MiB / 8191 MiB
memory per sequence: 51 MiB
 -> estimated maximum batch size: 99
adapters: r=32 params=0.60M (2.29 MiB)
!!!!!!!!
WARNING:
- The training sequence length is: T=64 (set with -t)
- The model's max sequence length is: max_seq_len=1024
You are attempting to train with a sequence length shorter than the model's max.
This will lead to unused parameters in the wpe position embedding weights.
If you know what you're doing you can ignore this warning.
If you're like ???, you are most likely misconfiguring your training run.
---> HINT: If you're training GPT-2 use -t 1024. If GPT-3, use -t 2048.
!!!!!!!!
Planned training steps: 200
Starting at step 0; validation reports measure completed loop steps.
Relative loss = 100 * current loss / first measured loss of that type.
Lower is better; this percentage is not token error rate or accuracy.
Teaching copy: inherited adapter training defects remain; see the top comment.
Step 0 of 200 had validation loss 5.325532 nats/token; loss relative to first validation: 100.00% (step 0 reference: 5.325532).
Step 1 of 200 had training loss 4.981215 nats/token; loss relative to first training: 100.00% (step 1 reference: 4.981215).
  Step details: gradient norm 36.1151 | learning rate 3.00e-04 | 24.40 ms | 2623 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 2 of 200 had training loss 5.043665 nats/token; loss relative to first training: 101.25% (step 1 reference: 4.981215).
  Step details: gradient norm 44.8534 | learning rate 3.00e-04 | 17.02 ms | 3759 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 3 of 200 had training loss 5.798073 nats/token; loss relative to first training: 116.40% (step 1 reference: 4.981215).
  Step details: gradient norm 27.7182 | learning rate 3.00e-04 | 18.20 ms | 3635 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 4 of 200 had training loss 5.185099 nats/token; loss relative to first training: 104.09% (step 1 reference: 4.981215).
  Step details: gradient norm 38.1241 | learning rate 3.00e-04 | 18.52 ms | 3572 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 5 of 200 had training loss 5.236744 nats/token; loss relative to first training: 105.13% (step 1 reference: 4.981215).
  Step details: gradient norm 38.7524 | learning rate 3.00e-04 | 18.10 ms | 3562 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 6 of 200 had training loss 4.945412 nats/token; loss relative to first training: 99.28% (step 1 reference: 4.981215).
  Step details: gradient norm 57.7504 | learning rate 3.00e-04 | 18.24 ms | 3550 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 7 of 200 had training loss 5.897269 nats/token; loss relative to first training: 118.39% (step 1 reference: 4.981215).
  Step details: gradient norm 26.9320 | learning rate 3.00e-04 | 17.28 ms | 3579 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 8 of 200 had training loss 4.562058 nats/token; loss relative to first training: 91.59% (step 1 reference: 4.981215).
  Step details: gradient norm 26.4305 | learning rate 3.00e-04 | 20.18 ms | 3512 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 9 of 200 had training loss 5.816571 nats/token; loss relative to first training: 116.77% (step 1 reference: 4.981215).
  Step details: gradient norm 30.6074 | learning rate 3.00e-04 | 17.29 ms | 3540 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 10 of 200 had training loss 5.615283 nats/token; loss relative to first training: 112.73% (step 1 reference: 4.981215).
  Step details: gradient norm 28.5531 | learning rate 3.00e-04 | 19.70 ms | 3500 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 11 of 200 had training loss 5.629881 nats/token; loss relative to first training: 113.02% (step 1 reference: 4.981215).
  Step details: gradient norm 43.5689 | learning rate 3.00e-04 | 17.04 ms | 3532 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 12 of 200 had training loss 5.653616 nats/token; loss relative to first training: 113.50% (step 1 reference: 4.981215).
  Step details: gradient norm 34.6251 | learning rate 3.00e-04 | 18.24 ms | 3529 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 13 of 200 had training loss 4.931967 nats/token; loss relative to first training: 99.01% (step 1 reference: 4.981215).
  Step details: gradient norm 32.2466 | learning rate 3.00e-04 | 21.55 ms | 3469 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 14 of 200 had training loss 5.037195 nats/token; loss relative to first training: 101.12% (step 1 reference: 4.981215).
  Step details: gradient norm 37.9581 | learning rate 3.00e-04 | 18.25 ms | 3473 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 15 of 200 had training loss 5.494430 nats/token; loss relative to first training: 110.30% (step 1 reference: 4.981215).
  Step details: gradient norm 46.3531 | learning rate 3.00e-04 | 18.33 ms | 3474 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 16 of 200 had training loss 4.832376 nats/token; loss relative to first training: 97.01% (step 1 reference: 4.981215).
  Step details: gradient norm 27.3823 | learning rate 3.00e-04 | 18.62 ms | 3471 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 17 of 200 had training loss 5.430913 nats/token; loss relative to first training: 109.03% (step 1 reference: 4.981215).
  Step details: gradient norm 45.5370 | learning rate 3.00e-04 | 18.38 ms | 3472 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 18 of 200 had training loss 5.392012 nats/token; loss relative to first training: 108.25% (step 1 reference: 4.981215).
  Step details: gradient norm 40.9939 | learning rate 3.00e-04 | 19.15 ms | 3461 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 19 of 200 had training loss 5.064080 nats/token; loss relative to first training: 101.66% (step 1 reference: 4.981215).
  Step details: gradient norm 29.6667 | learning rate 3.00e-04 | 23.45 ms | 3400 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 20 of 200 had training loss 4.924960 nats/token; loss relative to first training: 98.87% (step 1 reference: 4.981215).
  Step details: gradient norm 24.5624 | learning rate 3.00e-04 | 18.47 ms | 3405 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 20 of 200 had validation loss 5.319420 nats/token; loss relative to first validation: 99.89% (step 0 reference: 5.325532).
Step 21 of 200 had training loss 5.727859 nats/token; loss relative to first training: 114.99% (step 1 reference: 4.981215).
  Step details: gradient norm 38.1362 | learning rate 3.00e-04 | 21.02 ms | 3377 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 22 of 200 had training loss 4.576900 nats/token; loss relative to first training: 91.88% (step 1 reference: 4.981215).
  Step details: gradient norm 25.3197 | learning rate 3.00e-04 | 19.61 ms | 3369 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 23 of 200 had training loss 5.090511 nats/token; loss relative to first training: 102.19% (step 1 reference: 4.981215).
  Step details: gradient norm 30.5566 | learning rate 3.00e-04 | 20.81 ms | 3347 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 24 of 200 had training loss 5.550463 nats/token; loss relative to first training: 111.43% (step 1 reference: 4.981215).
  Step details: gradient norm 32.1979 | learning rate 3.00e-04 | 19.22 ms | 3346 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 25 of 200 had training loss 4.613642 nats/token; loss relative to first training: 92.62% (step 1 reference: 4.981215).
  Step details: gradient norm 25.8809 | learning rate 3.00e-04 | 19.35 ms | 3343 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 26 of 200 had training loss 5.177589 nats/token; loss relative to first training: 103.94% (step 1 reference: 4.981215).
  Step details: gradient norm 32.8848 | learning rate 3.00e-04 | 20.42 ms | 3329 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 27 of 200 had training loss 5.078773 nats/token; loss relative to first training: 101.96% (step 1 reference: 4.981215).
  Step details: gradient norm 25.8867 | learning rate 3.00e-04 | 19.84 ms | 3322 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 28 of 200 had training loss 4.520184 nats/token; loss relative to first training: 90.74% (step 1 reference: 4.981215).
  Step details: gradient norm 37.8588 | learning rate 3.00e-04 | 20.41 ms | 3309 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 29 of 200 had training loss 5.181998 nats/token; loss relative to first training: 104.03% (step 1 reference: 4.981215).
  Step details: gradient norm 31.8811 | learning rate 3.00e-04 | 20.29 ms | 3299 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 30 of 200 had training loss 4.940781 nats/token; loss relative to first training: 99.19% (step 1 reference: 4.981215).
  Step details: gradient norm 32.9404 | learning rate 3.00e-04 | 22.17 ms | 3272 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 31 of 200 had training loss 4.738319 nats/token; loss relative to first training: 95.12% (step 1 reference: 4.981215).
  Step details: gradient norm 28.1541 | learning rate 3.00e-04 | 22.69 ms | 3244 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 32 of 200 had training loss 4.786033 nats/token; loss relative to first training: 96.08% (step 1 reference: 4.981215).
  Step details: gradient norm 31.0108 | learning rate 3.00e-04 | 21.37 ms | 3228 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 33 of 200 had training loss 5.545306 nats/token; loss relative to first training: 111.32% (step 1 reference: 4.981215).
  Step details: gradient norm 39.6388 | learning rate 3.00e-04 | 22.51 ms | 3204 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 34 of 200 had training loss 5.021629 nats/token; loss relative to first training: 100.81% (step 1 reference: 4.981215).
  Step details: gradient norm 60.8934 | learning rate 3.00e-04 | 22.53 ms | 3182 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 35 of 200 had training loss 5.317007 nats/token; loss relative to first training: 106.74% (step 1 reference: 4.981215).
  Step details: gradient norm 43.0560 | learning rate 3.00e-04 | 22.80 ms | 3159 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 36 of 200 had training loss 5.326232 nats/token; loss relative to first training: 106.93% (step 1 reference: 4.981215).
  Step details: gradient norm 38.5083 | learning rate 3.00e-04 | 22.70 ms | 3139 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 37 of 200 had training loss 4.603750 nats/token; loss relative to first training: 92.42% (step 1 reference: 4.981215).
  Step details: gradient norm 47.3279 | learning rate 3.00e-04 | 22.49 ms | 3121 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 38 of 200 had training loss 5.053695 nats/token; loss relative to first training: 101.46% (step 1 reference: 4.981215).
  Step details: gradient norm 27.1760 | learning rate 3.00e-04 | 23.14 ms | 3101 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 39 of 200 had training loss 5.681299 nats/token; loss relative to first training: 114.05% (step 1 reference: 4.981215).
  Step details: gradient norm 35.2769 | learning rate 3.00e-04 | 23.53 ms | 3078 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 40 of 200 had training loss 4.762113 nats/token; loss relative to first training: 95.60% (step 1 reference: 4.981215).
  Step details: gradient norm 34.1548 | learning rate 3.00e-04 | 22.29 ms | 3066 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 40 of 200 had validation loss 5.306518 nats/token; loss relative to first validation: 99.64% (step 0 reference: 5.325532).
Step 41 of 200 had training loss 5.043900 nats/token; loss relative to first training: 101.26% (step 1 reference: 4.981215).
  Step details: gradient norm 34.0825 | learning rate 3.00e-04 | 20.23 ms | 3072 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 42 of 200 had training loss 4.962437 nats/token; loss relative to first training: 99.62% (step 1 reference: 4.981215).
  Step details: gradient norm 28.6952 | learning rate 3.00e-04 | 20.42 ms | 3075 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 43 of 200 had training loss 5.470983 nats/token; loss relative to first training: 109.83% (step 1 reference: 4.981215).
  Step details: gradient norm 36.3551 | learning rate 3.00e-04 | 20.27 ms | 3080 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 44 of 200 had training loss 4.665272 nats/token; loss relative to first training: 93.66% (step 1 reference: 4.981215).
  Step details: gradient norm 43.2009 | learning rate 3.00e-04 | 19.25 ms | 3094 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 45 of 200 had training loss 4.882253 nats/token; loss relative to first training: 98.01% (step 1 reference: 4.981215).
  Step details: gradient norm 37.4084 | learning rate 3.00e-04 | 19.72 ms | 3102 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 46 of 200 had training loss 5.138426 nats/token; loss relative to first training: 103.16% (step 1 reference: 4.981215).
  Step details: gradient norm 39.8481 | learning rate 3.00e-04 | 20.83 ms | 3101 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 47 of 200 had training loss 5.704744 nats/token; loss relative to first training: 114.53% (step 1 reference: 4.981215).
  Step details: gradient norm 34.5607 | learning rate 3.00e-04 | 19.63 ms | 3109 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 48 of 200 had training loss 4.668445 nats/token; loss relative to first training: 93.72% (step 1 reference: 4.981215).
  Step details: gradient norm 39.1186 | learning rate 3.00e-04 | 19.42 ms | 3120 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 49 of 200 had training loss 5.577337 nats/token; loss relative to first training: 111.97% (step 1 reference: 4.981215).
  Step details: gradient norm 41.6597 | learning rate 3.00e-04 | 17.93 ms | 3144 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 50 of 200 had training loss 4.939452 nats/token; loss relative to first training: 99.16% (step 1 reference: 4.981215).
  Step details: gradient norm 32.7824 | learning rate 3.00e-04 | 18.58 ms | 3161 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 51 of 200 had training loss 4.759198 nats/token; loss relative to first training: 95.54% (step 1 reference: 4.981215).
  Step details: gradient norm 29.3824 | learning rate 3.00e-04 | 17.89 ms | 3183 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 52 of 200 had training loss 4.499435 nats/token; loss relative to first training: 90.33% (step 1 reference: 4.981215).
  Step details: gradient norm 33.8207 | learning rate 3.00e-04 | 19.27 ms | 3191 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 53 of 200 had training loss 4.829110 nats/token; loss relative to first training: 96.95% (step 1 reference: 4.981215).
  Step details: gradient norm 30.9040 | learning rate 3.00e-04 | 17.42 ms | 3217 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 54 of 200 had training loss 5.383945 nats/token; loss relative to first training: 108.08% (step 1 reference: 4.981215).
  Step details: gradient norm 26.6556 | learning rate 3.00e-04 | 19.39 ms | 3221 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 55 of 200 had training loss 5.393835 nats/token; loss relative to first training: 108.28% (step 1 reference: 4.981215).
  Step details: gradient norm 34.9099 | learning rate 3.00e-04 | 18.13 ms | 3238 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 56 of 200 had training loss 4.478440 nats/token; loss relative to first training: 89.91% (step 1 reference: 4.981215).
  Step details: gradient norm 32.2332 | learning rate 3.00e-04 | 18.35 ms | 3251 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 57 of 200 had training loss 5.499231 nats/token; loss relative to first training: 110.40% (step 1 reference: 4.981215).
  Step details: gradient norm 33.1878 | learning rate 3.00e-04 | 19.04 ms | 3257 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 58 of 200 had training loss 4.622255 nats/token; loss relative to first training: 92.79% (step 1 reference: 4.981215).
  Step details: gradient norm 32.5653 | learning rate 3.00e-04 | 18.02 ms | 3272 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 59 of 200 had training loss 5.090656 nats/token; loss relative to first training: 102.20% (step 1 reference: 4.981215).
  Step details: gradient norm 26.2192 | learning rate 3.00e-04 | 18.62 ms | 3281 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 60 of 200 had training loss 5.407921 nats/token; loss relative to first training: 108.57% (step 1 reference: 4.981215).
  Step details: gradient norm 26.3271 | learning rate 3.00e-04 | 18.33 ms | 3292 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 60 of 200 had validation loss 5.293036 nats/token; loss relative to first validation: 99.39% (step 0 reference: 5.325532).
Step 61 of 200 had training loss 5.098307 nats/token; loss relative to first training: 102.35% (step 1 reference: 4.981215).
  Step details: gradient norm 30.0680 | learning rate 3.00e-04 | 19.45 ms | 3292 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 62 of 200 had training loss 4.936710 nats/token; loss relative to first training: 99.11% (step 1 reference: 4.981215).
  Step details: gradient norm 32.4945 | learning rate 3.00e-04 | 21.06 ms | 3279 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 63 of 200 had training loss 5.409326 nats/token; loss relative to first training: 108.59% (step 1 reference: 4.981215).
  Step details: gradient norm 35.7552 | learning rate 3.00e-04 | 20.16 ms | 3273 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 64 of 200 had training loss 4.869110 nats/token; loss relative to first training: 97.75% (step 1 reference: 4.981215).
  Step details: gradient norm 39.4914 | learning rate 3.00e-04 | 19.83 ms | 3271 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 65 of 200 had training loss 4.596824 nats/token; loss relative to first training: 92.28% (step 1 reference: 4.981215).
  Step details: gradient norm 28.6133 | learning rate 3.00e-04 | 19.89 ms | 3268 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 66 of 200 had training loss 5.066951 nats/token; loss relative to first training: 101.72% (step 1 reference: 4.981215).
  Step details: gradient norm 42.6912 | learning rate 3.00e-04 | 20.91 ms | 3258 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 67 of 200 had training loss 4.834317 nats/token; loss relative to first training: 97.05% (step 1 reference: 4.981215).
  Step details: gradient norm 29.3494 | learning rate 3.00e-04 | 20.37 ms | 3252 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 68 of 200 had training loss 4.619950 nats/token; loss relative to first training: 92.75% (step 1 reference: 4.981215).
  Step details: gradient norm 51.9343 | learning rate 3.00e-04 | 20.70 ms | 3243 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 69 of 200 had training loss 5.029195 nats/token; loss relative to first training: 100.96% (step 1 reference: 4.981215).
  Step details: gradient norm 41.8552 | learning rate 3.00e-04 | 20.38 ms | 3238 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 70 of 200 had training loss 5.283381 nats/token; loss relative to first training: 106.07% (step 1 reference: 4.981215).
  Step details: gradient norm 44.3518 | learning rate 3.00e-04 | 19.07 ms | 3244 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 71 of 200 had training loss 5.541421 nats/token; loss relative to first training: 111.25% (step 1 reference: 4.981215).
  Step details: gradient norm 35.2664 | learning rate 3.00e-04 | 17.45 ms | 3266 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 72 of 200 had training loss 4.791499 nats/token; loss relative to first training: 96.19% (step 1 reference: 4.981215).
  Step details: gradient norm 27.0892 | learning rate 3.00e-04 | 18.56 ms | 3275 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 73 of 200 had training loss 4.992763 nats/token; loss relative to first training: 100.23% (step 1 reference: 4.981215).
  Step details: gradient norm 27.9528 | learning rate 3.00e-04 | 17.61 ms | 3294 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 74 of 200 had training loss 5.506107 nats/token; loss relative to first training: 110.54% (step 1 reference: 4.981215).
  Step details: gradient norm 32.4258 | learning rate 3.00e-04 | 18.31 ms | 3304 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 75 of 200 had training loss 4.811340 nats/token; loss relative to first training: 96.59% (step 1 reference: 4.981215).
  Step details: gradient norm 29.0366 | learning rate 3.00e-04 | 17.65 ms | 3320 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 76 of 200 had training loss 4.421637 nats/token; loss relative to first training: 88.77% (step 1 reference: 4.981215).
  Step details: gradient norm 29.3679 | learning rate 3.00e-04 | 18.48 ms | 3328 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 77 of 200 had training loss 4.823132 nats/token; loss relative to first training: 96.83% (step 1 reference: 4.981215).
  Step details: gradient norm 31.5610 | learning rate 3.00e-04 | 17.50 ms | 3344 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 78 of 200 had training loss 5.304100 nats/token; loss relative to first training: 106.48% (step 1 reference: 4.981215).
  Step details: gradient norm 29.3394 | learning rate 3.00e-04 | 19.29 ms | 3343 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 79 of 200 had training loss 4.969275 nats/token; loss relative to first training: 99.76% (step 1 reference: 4.981215).
  Step details: gradient norm 28.7062 | learning rate 3.00e-04 | 17.57 ms | 3358 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 80 of 200 had training loss 5.034656 nats/token; loss relative to first training: 101.07% (step 1 reference: 4.981215).
  Step details: gradient norm 28.9033 | learning rate 3.00e-04 | 18.29 ms | 3366 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 80 of 200 had validation loss 5.302331 nats/token; loss relative to first validation: 99.56% (step 0 reference: 5.325532).
Step 81 of 200 had training loss 5.300815 nats/token; loss relative to first training: 106.42% (step 1 reference: 4.981215).
  Step details: gradient norm 36.4019 | learning rate 3.00e-04 | 17.40 ms | 3381 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 82 of 200 had training loss 5.652567 nats/token; loss relative to first training: 113.48% (step 1 reference: 4.981215).
  Step details: gradient norm 41.7334 | learning rate 3.00e-04 | 18.44 ms | 3386 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 83 of 200 had training loss 4.994418 nats/token; loss relative to first training: 100.27% (step 1 reference: 4.981215).
  Step details: gradient norm 31.9608 | learning rate 3.00e-04 | 18.75 ms | 3387 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 84 of 200 had training loss 5.792542 nats/token; loss relative to first training: 116.29% (step 1 reference: 4.981215).
  Step details: gradient norm 53.7598 | learning rate 3.00e-04 | 18.75 ms | 3389 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 85 of 200 had training loss 5.219641 nats/token; loss relative to first training: 104.79% (step 1 reference: 4.981215).
  Step details: gradient norm 43.3401 | learning rate 3.00e-04 | 17.50 ms | 3402 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 86 of 200 had training loss 4.981050 nats/token; loss relative to first training: 100.00% (step 1 reference: 4.981215).
  Step details: gradient norm 43.7996 | learning rate 3.00e-04 | 18.84 ms | 3402 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 87 of 200 had training loss 4.500578 nats/token; loss relative to first training: 90.35% (step 1 reference: 4.981215).
  Step details: gradient norm 27.3293 | learning rate 3.00e-04 | 17.64 ms | 3414 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 88 of 200 had training loss 5.109611 nats/token; loss relative to first training: 102.58% (step 1 reference: 4.981215).
  Step details: gradient norm 31.6019 | learning rate 3.00e-04 | 23.20 ms | 3380 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 89 of 200 had training loss 5.806528 nats/token; loss relative to first training: 116.57% (step 1 reference: 4.981215).
  Step details: gradient norm 34.8734 | learning rate 3.00e-04 | 21.09 ms | 3363 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 90 of 200 had training loss 4.714486 nats/token; loss relative to first training: 94.65% (step 1 reference: 4.981215).
  Step details: gradient norm 32.3734 | learning rate 3.00e-04 | 17.84 ms | 3374 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 91 of 200 had training loss 4.945698 nats/token; loss relative to first training: 99.29% (step 1 reference: 4.981215).
  Step details: gradient norm 35.9809 | learning rate 3.00e-04 | 18.86 ms | 3375 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 92 of 200 had training loss 4.592280 nats/token; loss relative to first training: 92.19% (step 1 reference: 4.981215).
  Step details: gradient norm 32.5072 | learning rate 3.00e-04 | 17.64 ms | 3388 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 93 of 200 had training loss 5.183741 nats/token; loss relative to first training: 104.07% (step 1 reference: 4.981215).
  Step details: gradient norm 33.9578 | learning rate 3.00e-04 | 18.32 ms | 3393 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 94 of 200 had training loss 4.654532 nats/token; loss relative to first training: 93.44% (step 1 reference: 4.981215).
  Step details: gradient norm 34.1746 | learning rate 3.00e-04 | 19.48 ms | 3388 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 95 of 200 had training loss 4.777038 nats/token; loss relative to first training: 95.90% (step 1 reference: 4.981215).
  Step details: gradient norm 44.6330 | learning rate 3.00e-04 | 17.96 ms | 3397 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 96 of 200 had training loss 4.495411 nats/token; loss relative to first training: 90.25% (step 1 reference: 4.981215).
  Step details: gradient norm 46.5899 | learning rate 3.00e-04 | 19.18 ms | 3394 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 97 of 200 had training loss 4.945185 nats/token; loss relative to first training: 99.28% (step 1 reference: 4.981215).
  Step details: gradient norm 31.4583 | learning rate 3.00e-04 | 18.66 ms | 3396 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 98 of 200 had training loss 4.239321 nats/token; loss relative to first training: 85.11% (step 1 reference: 4.981215).
  Step details: gradient norm 30.5905 | learning rate 3.00e-04 | 18.09 ms | 3403 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 99 of 200 had training loss 4.834732 nats/token; loss relative to first training: 97.06% (step 1 reference: 4.981215).
  Step details: gradient norm 49.5762 | learning rate 3.00e-04 | 19.10 ms | 3400 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 100 of 200 had training loss 5.496819 nats/token; loss relative to first training: 110.35% (step 1 reference: 4.981215).
  Step details: gradient norm 33.8419 | learning rate 3.00e-04 | 20.34 ms | 3387 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 100 of 200 had validation loss 5.357710 nats/token; loss relative to first validation: 100.60% (step 0 reference: 5.325532).
Step 101 of 200 had training loss 5.186984 nats/token; loss relative to first training: 104.13% (step 1 reference: 4.981215).
  Step details: gradient norm 55.9225 | learning rate 3.00e-04 | 19.97 ms | 3378 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 102 of 200 had training loss 5.555123 nats/token; loss relative to first training: 111.52% (step 1 reference: 4.981215).
  Step details: gradient norm 27.4612 | learning rate 3.00e-04 | 20.10 ms | 3368 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 103 of 200 had training loss 5.748739 nats/token; loss relative to first training: 115.41% (step 1 reference: 4.981215).
  Step details: gradient norm 57.1082 | learning rate 3.00e-04 | 20.59 ms | 3355 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 104 of 200 had training loss 5.351254 nats/token; loss relative to first training: 107.43% (step 1 reference: 4.981215).
  Step details: gradient norm 31.0347 | learning rate 3.00e-04 | 19.87 ms | 3349 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 105 of 200 had training loss 5.017042 nats/token; loss relative to first training: 100.72% (step 1 reference: 4.981215).
  Step details: gradient norm 28.7406 | learning rate 3.00e-04 | 23.42 ms | 3318 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 106 of 200 had training loss 5.783326 nats/token; loss relative to first training: 116.10% (step 1 reference: 4.981215).
  Step details: gradient norm 62.3206 | learning rate 3.00e-04 | 21.22 ms | 3303 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 107 of 200 had training loss 5.792194 nats/token; loss relative to first training: 116.28% (step 1 reference: 4.981215).
  Step details: gradient norm 46.4325 | learning rate 3.00e-04 | 20.35 ms | 3295 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 108 of 200 had training loss 5.104561 nats/token; loss relative to first training: 102.48% (step 1 reference: 4.981215).
  Step details: gradient norm 31.6697 | learning rate 3.00e-04 | 20.57 ms | 3285 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 109 of 200 had training loss 5.949661 nats/token; loss relative to first training: 119.44% (step 1 reference: 4.981215).
  Step details: gradient norm 60.1059 | learning rate 3.00e-04 | 20.55 ms | 3277 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 110 of 200 had training loss 4.347309 nats/token; loss relative to first training: 87.27% (step 1 reference: 4.981215).
  Step details: gradient norm 64.4340 | learning rate 3.00e-04 | 18.84 ms | 3283 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 111 of 200 had training loss 4.702516 nats/token; loss relative to first training: 94.41% (step 1 reference: 4.981215).
  Step details: gradient norm 69.6366 | learning rate 3.00e-04 | 19.74 ms | 3281 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 112 of 200 had training loss 5.307831 nats/token; loss relative to first training: 106.56% (step 1 reference: 4.981215).
  Step details: gradient norm 55.1730 | learning rate 3.00e-04 | 19.93 ms | 3277 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 113 of 200 had training loss 5.211235 nats/token; loss relative to first training: 104.62% (step 1 reference: 4.981215).
  Step details: gradient norm 50.0948 | learning rate 3.00e-04 | 20.63 ms | 3268 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 114 of 200 had training loss 5.088500 nats/token; loss relative to first training: 102.15% (step 1 reference: 4.981215).
  Step details: gradient norm 59.3199 | learning rate 3.00e-04 | 20.42 ms | 3262 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 115 of 200 had training loss 4.715091 nats/token; loss relative to first training: 94.66% (step 1 reference: 4.981215).
  Step details: gradient norm 29.8626 | learning rate 3.00e-04 | 20.16 ms | 3257 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 116 of 200 had training loss 5.353735 nats/token; loss relative to first training: 107.48% (step 1 reference: 4.981215).
  Step details: gradient norm 54.9895 | learning rate 3.00e-04 | 20.65 ms | 3249 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 117 of 200 had training loss 4.915546 nats/token; loss relative to first training: 98.68% (step 1 reference: 4.981215).
  Step details: gradient norm 76.8194 | learning rate 3.00e-04 | 19.42 ms | 3252 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 118 of 200 had training loss 4.990005 nats/token; loss relative to first training: 100.18% (step 1 reference: 4.981215).
  Step details: gradient norm 46.6641 | learning rate 3.00e-04 | 19.54 ms | 3253 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 119 of 200 had training loss 4.962613 nats/token; loss relative to first training: 99.63% (step 1 reference: 4.981215).
  Step details: gradient norm 39.1403 | learning rate 3.00e-04 | 20.10 ms | 3249 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 120 of 200 had training loss 5.153431 nats/token; loss relative to first training: 103.46% (step 1 reference: 4.981215).
  Step details: gradient norm 80.8427 | learning rate 3.00e-04 | 20.07 ms | 3246 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 120 of 200 had validation loss 5.451034 nats/token; loss relative to first validation: 102.36% (step 0 reference: 5.325532).
Step 121 of 200 had training loss 4.682160 nats/token; loss relative to first training: 94.00% (step 1 reference: 4.981215).
  Step details: gradient norm 69.5467 | learning rate 3.00e-04 | 18.62 ms | 3256 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 122 of 200 had training loss 5.132820 nats/token; loss relative to first training: 103.04% (step 1 reference: 4.981215).
  Step details: gradient norm 113.0416 | learning rate 3.00e-04 | 17.75 ms | 3273 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 123 of 200 had training loss 5.601258 nats/token; loss relative to first training: 112.45% (step 1 reference: 4.981215).
  Step details: gradient norm 126.7012 | learning rate 3.00e-04 | 18.34 ms | 3284 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 124 of 200 had training loss 5.514358 nats/token; loss relative to first training: 110.70% (step 1 reference: 4.981215).
  Step details: gradient norm 118.9760 | learning rate 3.00e-04 | 18.60 ms | 3292 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 125 of 200 had training loss 4.463631 nats/token; loss relative to first training: 89.61% (step 1 reference: 4.981215).
  Step details: gradient norm 183.7474 | learning rate 3.00e-04 | 17.06 ms | 3315 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 126 of 200 had training loss 5.190757 nats/token; loss relative to first training: 104.21% (step 1 reference: 4.981215).
  Step details: gradient norm 146.5801 | learning rate 3.00e-04 | 18.56 ms | 3322 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 127 of 200 had training loss 4.814627 nats/token; loss relative to first training: 96.66% (step 1 reference: 4.981215).
  Step details: gradient norm 188.0586 | learning rate 3.00e-04 | 18.71 ms | 3327 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 128 of 200 had training loss 5.495225 nats/token; loss relative to first training: 110.32% (step 1 reference: 4.981215).
  Step details: gradient norm 326.9973 | learning rate 3.00e-04 | 19.39 ms | 3325 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 129 of 200 had training loss 4.630729 nats/token; loss relative to first training: 92.96% (step 1 reference: 4.981215).
  Step details: gradient norm 292.5859 | learning rate 3.00e-04 | 18.57 ms | 3331 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 130 of 200 had training loss 5.453997 nats/token; loss relative to first training: 109.49% (step 1 reference: 4.981215).
  Step details: gradient norm 247.3752 | learning rate 3.00e-04 | 18.66 ms | 3336 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 131 of 200 had training loss 4.199597 nats/token; loss relative to first training: 84.31% (step 1 reference: 4.981215).
  Step details: gradient norm 329.7313 | learning rate 3.00e-04 | 17.33 ms | 3354 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 132 of 200 had training loss 4.666892 nats/token; loss relative to first training: 93.69% (step 1 reference: 4.981215).
  Step details: gradient norm 448.3166 | learning rate 3.00e-04 | 18.57 ms | 3359 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 133 of 200 had training loss 4.542295 nats/token; loss relative to first training: 91.19% (step 1 reference: 4.981215).
  Step details: gradient norm 434.2148 | learning rate 3.00e-04 | 17.74 ms | 3371 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 134 of 200 had training loss 5.220245 nats/token; loss relative to first training: 104.80% (step 1 reference: 4.981215).
  Step details: gradient norm 534.7798 | learning rate 3.00e-04 | 17.70 ms | 3384 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 135 of 200 had training loss 5.504363 nats/token; loss relative to first training: 110.50% (step 1 reference: 4.981215).
  Step details: gradient norm 650.1670 | learning rate 3.00e-04 | 19.73 ms | 3377 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 136 of 200 had training loss 4.803865 nats/token; loss relative to first training: 96.44% (step 1 reference: 4.981215).
  Step details: gradient norm 746.7120 | learning rate 3.00e-04 | 17.20 ms | 3394 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 137 of 200 had training loss 5.269794 nats/token; loss relative to first training: 105.79% (step 1 reference: 4.981215).
  Step details: gradient norm 641.9419 | learning rate 3.00e-04 | 20.70 ms | 3379 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 138 of 200 had training loss 4.768250 nats/token; loss relative to first training: 95.72% (step 1 reference: 4.981215).
  Step details: gradient norm 744.9371 | learning rate 3.00e-04 | 20.70 ms | 3364 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 139 of 200 had training loss 5.075925 nats/token; loss relative to first training: 101.90% (step 1 reference: 4.981215).
  Step details: gradient norm 889.3046 | learning rate 3.00e-04 | 21.45 ms | 3345 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 140 of 200 had training loss 5.411349 nats/token; loss relative to first training: 108.64% (step 1 reference: 4.981215).
  Step details: gradient norm 1108.8918 | learning rate 3.00e-04 | 19.84 ms | 3339 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 140 of 200 had validation loss 5.575615 nats/token; loss relative to first validation: 104.70% (step 0 reference: 5.325532).
Step 141 of 200 had training loss 5.081310 nats/token; loss relative to first training: 102.01% (step 1 reference: 4.981215).
  Step details: gradient norm 1279.9000 | learning rate 3.00e-04 | 17.52 ms | 3355 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 142 of 200 had training loss 5.297473 nats/token; loss relative to first training: 106.35% (step 1 reference: 4.981215).
  Step details: gradient norm 1447.3666 | learning rate 3.00e-04 | 18.89 ms | 3357 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 143 of 200 had training loss 5.065684 nats/token; loss relative to first training: 101.70% (step 1 reference: 4.981215).
  Step details: gradient norm 1959.1780 | learning rate 3.00e-04 | 18.69 ms | 3360 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 144 of 200 had training loss 4.915490 nats/token; loss relative to first training: 98.68% (step 1 reference: 4.981215).
  Step details: gradient norm 1375.2994 | learning rate 3.00e-04 | 17.02 ms | 3380 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 145 of 200 had training loss 5.910953 nats/token; loss relative to first training: 118.66% (step 1 reference: 4.981215).
  Step details: gradient norm 1481.8082 | learning rate 3.00e-04 | 19.35 ms | 3376 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 146 of 200 had training loss 5.773628 nats/token; loss relative to first training: 115.91% (step 1 reference: 4.981215).
  Step details: gradient norm 2132.0574 | learning rate 3.00e-04 | 17.14 ms | 3394 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 147 of 200 had training loss 5.643678 nats/token; loss relative to first training: 113.30% (step 1 reference: 4.981215).
  Step details: gradient norm 2939.2937 | learning rate 3.00e-04 | 17.63 ms | 3406 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 148 of 200 had training loss 5.197543 nats/token; loss relative to first training: 104.34% (step 1 reference: 4.981215).
  Step details: gradient norm 2670.6531 | learning rate 3.00e-04 | 18.20 ms | 3412 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 149 of 200 had training loss 4.633760 nats/token; loss relative to first training: 93.02% (step 1 reference: 4.981215).
  Step details: gradient norm 2836.6824 | learning rate 3.00e-04 | 18.38 ms | 3415 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 150 of 200 had training loss 4.911520 nats/token; loss relative to first training: 98.60% (step 1 reference: 4.981215).
  Step details: gradient norm 3835.7463 | learning rate 3.00e-04 | 18.71 ms | 3415 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 151 of 200 had training loss 5.279140 nats/token; loss relative to first training: 105.98% (step 1 reference: 4.981215).
  Step details: gradient norm 3341.3303 | learning rate 3.00e-04 | 17.74 ms | 3425 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 152 of 200 had training loss 5.699568 nats/token; loss relative to first training: 114.42% (step 1 reference: 4.981215).
  Step details: gradient norm 3992.7686 | learning rate 3.00e-04 | 17.71 ms | 3434 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 153 of 200 had training loss 5.587042 nats/token; loss relative to first training: 112.16% (step 1 reference: 4.981215).
  Step details: gradient norm 3913.5044 | learning rate 3.00e-04 | 18.08 ms | 3440 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 154 of 200 had training loss 5.717347 nats/token; loss relative to first training: 114.78% (step 1 reference: 4.981215).
  Step details: gradient norm 5422.5288 | learning rate 3.00e-04 | 18.23 ms | 3443 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 155 of 200 had training loss 5.131121 nats/token; loss relative to first training: 103.01% (step 1 reference: 4.981215).
  Step details: gradient norm 5547.0117 | learning rate 3.00e-04 | 18.28 ms | 3446 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 156 of 200 had training loss 5.668833 nats/token; loss relative to first training: 113.80% (step 1 reference: 4.981215).
  Step details: gradient norm 7273.1309 | learning rate 3.00e-04 | 19.13 ms | 3441 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 157 of 200 had training loss 5.492451 nats/token; loss relative to first training: 110.26% (step 1 reference: 4.981215).
  Step details: gradient norm 8549.2393 | learning rate 3.00e-04 | 16.94 ms | 3458 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 158 of 200 had training loss 5.686593 nats/token; loss relative to first training: 114.16% (step 1 reference: 4.981215).
  Step details: gradient norm 9926.1270 | learning rate 3.00e-04 | 18.49 ms | 3458 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 159 of 200 had training loss 5.838572 nats/token; loss relative to first training: 117.21% (step 1 reference: 4.981215).
  Step details: gradient norm 11755.6133 | learning rate 3.00e-04 | 18.24 ms | 3461 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 160 of 200 had training loss 6.088783 nats/token; loss relative to first training: 122.23% (step 1 reference: 4.981215).
  Step details: gradient norm 13580.7051 | learning rate 3.00e-04 | 18.22 ms | 3463 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 160 of 200 had validation loss 6.107953 nats/token; loss relative to first validation: 114.69% (step 0 reference: 5.325532).
Step 161 of 200 had training loss 5.444592 nats/token; loss relative to first training: 109.30% (step 1 reference: 4.981215).
  Step details: gradient norm 13404.2461 | learning rate 3.00e-04 | 17.51 ms | 3473 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 162 of 200 had training loss 5.432074 nats/token; loss relative to first training: 109.05% (step 1 reference: 4.981215).
  Step details: gradient norm 13493.0830 | learning rate 3.00e-04 | 18.18 ms | 3475 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 163 of 200 had training loss 6.236499 nats/token; loss relative to first training: 125.20% (step 1 reference: 4.981215).
  Step details: gradient norm 23330.6387 | learning rate 3.00e-04 | 17.19 ms | 3487 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 164 of 200 had training loss 6.113267 nats/token; loss relative to first training: 122.73% (step 1 reference: 4.981215).
  Step details: gradient norm 26753.6133 | learning rate 3.00e-04 | 18.68 ms | 3484 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 165 of 200 had training loss 6.283515 nats/token; loss relative to first training: 126.14% (step 1 reference: 4.981215).
  Step details: gradient norm 27216.2871 | learning rate 3.00e-04 | 17.05 ms | 3498 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 166 of 200 had training loss 6.317945 nats/token; loss relative to first training: 126.84% (step 1 reference: 4.981215).
  Step details: gradient norm 37855.6367 | learning rate 3.00e-04 | 18.32 ms | 3498 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 167 of 200 had training loss 6.556222 nats/token; loss relative to first training: 131.62% (step 1 reference: 4.981215).
  Step details: gradient norm 41256.2148 | learning rate 3.00e-04 | 17.84 ms | 3502 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 168 of 200 had training loss 6.161782 nats/token; loss relative to first training: 123.70% (step 1 reference: 4.981215).
  Step details: gradient norm 36205.4062 | learning rate 3.00e-04 | 17.91 ms | 3506 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 169 of 200 had training loss 6.793384 nats/token; loss relative to first training: 136.38% (step 1 reference: 4.981215).
  Step details: gradient norm 61218.5586 | learning rate 3.00e-04 | 18.69 ms | 3502 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 170 of 200 had training loss 7.310444 nats/token; loss relative to first training: 146.76% (step 1 reference: 4.981215).
  Step details: gradient norm 62539.9062 | learning rate 3.00e-04 | 18.18 ms | 3503 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 171 of 200 had training loss 6.852766 nats/token; loss relative to first training: 137.57% (step 1 reference: 4.981215).
  Step details: gradient norm 70071.0859 | learning rate 3.00e-04 | 18.29 ms | 3502 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 172 of 200 had training loss 7.094427 nats/token; loss relative to first training: 142.42% (step 1 reference: 4.981215).
  Step details: gradient norm 83475.6641 | learning rate 3.00e-04 | 17.57 ms | 3509 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 173 of 200 had training loss 6.485745 nats/token; loss relative to first training: 130.20% (step 1 reference: 4.981215).
  Step details: gradient norm 62210.1211 | learning rate 3.00e-04 | 20.83 ms | 3488 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 174 of 200 had training loss 7.120486 nats/token; loss relative to first training: 142.95% (step 1 reference: 4.981215).
  Step details: gradient norm 103028.2656 | learning rate 3.00e-04 | 20.81 ms | 3467 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 175 of 200 had training loss 7.425338 nats/token; loss relative to first training: 149.07% (step 1 reference: 4.981215).
  Step details: gradient norm 128782.2656 | learning rate 3.00e-04 | 20.46 ms | 3450 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 176 of 200 had training loss 8.328116 nats/token; loss relative to first training: 167.19% (step 1 reference: 4.981215).
  Step details: gradient norm 157920.5156 | learning rate 3.00e-04 | 20.40 ms | 3434 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 177 of 200 had training loss 7.989642 nats/token; loss relative to first training: 160.40% (step 1 reference: 4.981215).
  Step details: gradient norm 166528.4219 | learning rate 3.00e-04 | 20.55 ms | 3418 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 178 of 200 had training loss 8.005414 nats/token; loss relative to first training: 160.71% (step 1 reference: 4.981215).
  Step details: gradient norm 200657.2188 | learning rate 3.00e-04 | 20.88 ms | 3401 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 179 of 200 had training loss 9.685499 nats/token; loss relative to first training: 194.44% (step 1 reference: 4.981215).
  Step details: gradient norm 242035.8125 | learning rate 3.00e-04 | 19.56 ms | 3394 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 180 of 200 had training loss 8.057528 nats/token; loss relative to first training: 161.76% (step 1 reference: 4.981215).
  Step details: gradient norm 209541.5000 | learning rate 3.00e-04 | 19.52 ms | 3388 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 180 of 200 had validation loss 8.692907 nats/token; loss relative to first validation: 163.23% (step 0 reference: 5.325532).
Step 181 of 200 had training loss 7.833770 nats/token; loss relative to first training: 157.27% (step 1 reference: 4.981215).
  Step details: gradient norm 183261.5156 | learning rate 3.00e-04 | 19.96 ms | 3379 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 182 of 200 had training loss 8.885852 nats/token; loss relative to first training: 178.39% (step 1 reference: 4.981215).
  Step details: gradient norm 298402.5938 | learning rate 3.00e-04 | 20.27 ms | 3368 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 183 of 200 had training loss 9.197239 nats/token; loss relative to first training: 184.64% (step 1 reference: 4.981215).
  Step details: gradient norm 322887.6250 | learning rate 3.00e-04 | 19.92 ms | 3361 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 184 of 200 had training loss 9.923166 nats/token; loss relative to first training: 199.21% (step 1 reference: 4.981215).
  Step details: gradient norm 408066.0000 | learning rate 3.00e-04 | 19.29 ms | 3358 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 185 of 200 had training loss 9.739154 nats/token; loss relative to first training: 195.52% (step 1 reference: 4.981215).
  Step details: gradient norm 399769.9688 | learning rate 3.00e-04 | 19.86 ms | 3352 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 186 of 200 had training loss 10.054033 nats/token; loss relative to first training: 201.84% (step 1 reference: 4.981215).
  Step details: gradient norm 499363.6250 | learning rate 3.00e-04 | 19.03 ms | 3352 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 187 of 200 had training loss 9.302685 nats/token; loss relative to first training: 186.76% (step 1 reference: 4.981215).
  Step details: gradient norm 512005.6875 | learning rate 3.00e-04 | 20.45 ms | 3341 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 188 of 200 had training loss 10.006342 nats/token; loss relative to first training: 200.88% (step 1 reference: 4.981215).
  Step details: gradient norm 595174.5000 | learning rate 3.00e-04 | 20.11 ms | 3333 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 189 of 200 had training loss 10.340162 nats/token; loss relative to first training: 207.58% (step 1 reference: 4.981215).
  Step details: gradient norm 758762.2500 | learning rate 3.00e-04 | 20.51 ms | 3323 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 190 of 200 had training loss 10.364863 nats/token; loss relative to first training: 208.08% (step 1 reference: 4.981215).
  Step details: gradient norm 729632.8750 | learning rate 3.00e-04 | 19.96 ms | 3317 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 191 of 200 had training loss 10.119747 nats/token; loss relative to first training: 203.16% (step 1 reference: 4.981215).
  Step details: gradient norm 959203.8750 | learning rate 3.00e-04 | 20.27 ms | 3309 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 192 of 200 had training loss 11.663149 nats/token; loss relative to first training: 234.14% (step 1 reference: 4.981215).
  Step details: gradient norm 1032534.4375 | learning rate 3.00e-04 | 20.36 ms | 3301 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 193 of 200 had training loss 11.530534 nats/token; loss relative to first training: 231.48% (step 1 reference: 4.981215).
  Step details: gradient norm 1059228.0000 | learning rate 3.00e-04 | 17.94 ms | 3314 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 194 of 200 had training loss 11.383003 nats/token; loss relative to first training: 228.52% (step 1 reference: 4.981215).
  Step details: gradient norm 1359249.7500 | learning rate 3.00e-04 | 18.00 ms | 3326 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 195 of 200 had training loss 12.000937 nats/token; loss relative to first training: 240.92% (step 1 reference: 4.981215).
  Step details: gradient norm 1222568.6250 | learning rate 3.00e-04 | 19.04 ms | 3328 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 196 of 200 had training loss 11.863321 nats/token; loss relative to first training: 238.16% (step 1 reference: 4.981215).
  Step details: gradient norm 1386613.3750 | learning rate 3.00e-04 | 18.18 ms | 3337 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 197 of 200 had training loss 11.610422 nats/token; loss relative to first training: 233.08% (step 1 reference: 4.981215).
  Step details: gradient norm 1692388.3750 | learning rate 3.00e-04 | 17.86 ms | 3350 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 198 of 200 had training loss 13.024540 nats/token; loss relative to first training: 261.47% (step 1 reference: 4.981215).
  Step details: gradient norm 1621543.8750 | learning rate 3.00e-04 | 18.55 ms | 3355 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 199 of 200 had training loss 11.837177 nats/token; loss relative to first training: 237.64% (step 1 reference: 4.981215).
  Step details: gradient norm 2190932.0000 | learning rate 3.00e-04 | 18.02 ms | 3365 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 200 of 200 had training loss 12.221046 nats/token; loss relative to first training: 245.34% (step 1 reference: 4.981215).
  Step details: gradient norm 2132942.2500 | learning rate 3.00e-04 | 18.42 ms | 3370 tokens/s
  Estimated GPU arithmetic utilization: unavailable for this GPU.
Step 200 of 200 had validation loss 12.772885 nats/token; loss relative to first validation: 239.84% (step 0 reference: 5.325532).
Writing checkpoint at step 200
Writing model to /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw/checkpoints/model_00000200.bin
Writing state to /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw/checkpoints/state_00000200_00000.bin
Writing adapter parameters to /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw/checkpoints/adapter_params_00000200.bin
Average step time after warmup: 19.266 ms.

Trainer exit status: 0
Run directory: /home/kroix/projects/SAGE_Adapter_Experiment/llmc-gpt2/runs/test_adapter_copy_20261105_1hWAVw
```
