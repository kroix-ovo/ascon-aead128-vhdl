# p8 pipelining: routed comparison

Routed timing on xc7a100tcsg324-1 (Vivado 2023.2), registered harness. Cycles from GHDL simulation. Latency = cycles x shortest passing period. No board measurement.

Speedup columns: vs A under the same strategy, and vs A at its best tested period (5.9 ns).

| Variant | Strategy | Block interval (cyc) | Pass period ns (MHz) | Next fail ns | Block interval ns | Speedup vs A (same strategy) | Speedup vs best A | Needed f ratio | Achieved f ratio | p8 ns | 1 KiB enc ns | Core LUT | Core FF |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| A | default | 12 | 6.000 (166.7) | 5.950 | 72.0 | 1.0 | 0.9833 | 1.0 | 1.0 | 48.0 | 4806.0 | 2366 | 1080 |
| A | explore | 12 | 5.900 (169.5) | 5.850 | 70.8 | 1.0 | 1.0 | 1.0 | 1.0 | 47.2 | 4725.9 | 2369 | 1080 |
| A | retime | 12 | 6.000 (166.7) | 5.950 | 72.0 | 1.0 | 0.9833 | 1.0 | 1.0 | 48.0 | 4806.0 | 2346 | 2453 |
| A_ctrl1 | default | 12 | 4.700 (212.8) | 4.650 | 56.4 | 1.2766 | 1.2553 | 1.0 | 1.2766 | 37.6 | 3764.7 | 2128 | 1075 |
| A_ctrl2 | default | 12 | 4.300 (232.6) | 4.250 | 51.6 | 1.3953 | 1.3721 | 1.0 | 1.3953 | 34.4 | 3444.3 | 2266 | 1090 |
| A_ctrl2 | explore | 12 | 4.150 (241.0) | 4.100 | 49.8 | 1.4217 | 1.4217 | 1.0 | 1.4217 | 33.2 | 3324.15 | 2271 | 1090 |
| A_ctrl2 | retime | 12 | 4.450 (224.7) | 4.400 | 53.4 | 1.3483 | 1.3258 | 1.0 | 1.3483 | 35.6 | 3564.45 | 2259 | 1103 |
| B_2stage | default | 20 | 6.200 (161.3) | 6.150 | 124.0 | 0.5806 | 0.571 | 1.6667 | 0.9677 | 99.2 | 8289.4 | 2381 | 1395 |
| C_3stage | default | 28 | 6.350 (157.5) | 6.300 | 177.8 | 0.4049 | 0.3982 | 2.3333 | 0.9449 | 152.4 | 11893.55 | 2562 | 1718 |
| D | default | 20 | 4.500 (222.2) | 4.450 | 90.0 | 0.8 | 0.7867 | 1.6667 | 1.3333 | 72.0 | 6016.5 | 2266 | 1407 |
| D | explore | 20 | 4.300 (232.6) | 4.250 | 86.0 | 0.8233 | 0.8233 | 1.6667 | 1.3721 | 68.8 | 5749.1 | 2266 | 1407 |
| D | retime | 20 | 4.550 (219.8) | 4.500 | 91.0 | 0.7912 | 0.778 | 1.6667 | 1.3187 | 72.8 | 6083.35 | 2266 | 1423 |

## Whole-message latency at each variant's passing clock (default strategy, unstalled)

| Variant | Workload | Cycles | ns | Baseline cycles | Speedup | First out_valid (cyc / ns) |
|---|---|---|---|---|---|---|
| A | ad0_msg0_enc | 34 | 204.0 | 34 | 1.0 | - |
| A | ad0_msg0_dec | 34 | 204.0 | 34 | 1.0 | - |
| A | ad0_msg16_enc | 45 | 270.0 | 45 | 1.0 | 17 / 102.0 |
| A | ad0_msg16_dec | 45 | 270.0 | 45 | 1.0 | 17 / 102.0 |
| A | ad0_msg32_enc | 57 | 342.0 | 57 | 1.0 | 17 / 102.0 |
| A | ad0_msg32_dec | 57 | 342.0 | 57 | 1.0 | 17 / 102.0 |
| A | ad0_msg1024_enc | 801 | 4806.0 | 801 | 1.0 | 17 / 102.0 |
| A | ad0_msg1024_dec | 801 | 4806.0 | 801 | 1.0 | 17 / 102.0 |
| A | ad0_msg4096_enc | 3105 | 18630.0 | 3105 | 1.0 | 17 / 102.0 |
| A | ad0_msg4096_dec | 3105 | 18630.0 | 3105 | 1.0 | 17 / 102.0 |
| A | ad16_msg0_enc | 54 | 324.0 | 54 | 1.0 | - |
| A | ad16_msg0_dec | 54 | 324.0 | 54 | 1.0 | - |
| A | ad16_msg16_enc | 65 | 390.0 | 65 | 1.0 | 37 / 222.0 |
| A | ad16_msg16_dec | 65 | 390.0 | 65 | 1.0 | 37 / 222.0 |
| A | ad16_msg32_enc | 77 | 462.0 | 77 | 1.0 | 37 / 222.0 |
| A | ad16_msg32_dec | 77 | 462.0 | 77 | 1.0 | 37 / 222.0 |
| A | ad16_msg1024_enc | 821 | 4926.0 | 821 | 1.0 | 37 / 222.0 |
| A | ad16_msg1024_dec | 821 | 4926.0 | 821 | 1.0 | 37 / 222.0 |
| A | ad16_msg4096_enc | 3125 | 18750.0 | 3125 | 1.0 | 37 / 222.0 |
| A | ad16_msg4096_dec | 3125 | 18750.0 | 3125 | 1.0 | 37 / 222.0 |
| A_ctrl1 | ad0_msg0_enc | 34 | 159.8 | 34 | 1.2766 | - |
| A_ctrl1 | ad0_msg0_dec | 34 | 159.8 | 34 | 1.2766 | - |
| A_ctrl1 | ad0_msg16_enc | 45 | 211.5 | 45 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad0_msg16_dec | 45 | 211.5 | 45 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad0_msg32_enc | 57 | 267.9 | 57 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad0_msg32_dec | 57 | 267.9 | 57 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad0_msg1024_enc | 801 | 3764.7 | 801 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad0_msg1024_dec | 801 | 3764.7 | 801 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad0_msg4096_enc | 3105 | 14593.5 | 3105 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad0_msg4096_dec | 3105 | 14593.5 | 3105 | 1.2766 | 17 / 79.9 |
| A_ctrl1 | ad16_msg0_enc | 54 | 253.8 | 54 | 1.2766 | - |
| A_ctrl1 | ad16_msg0_dec | 54 | 253.8 | 54 | 1.2766 | - |
| A_ctrl1 | ad16_msg16_enc | 65 | 305.5 | 65 | 1.2766 | 37 / 173.9 |
| A_ctrl1 | ad16_msg16_dec | 65 | 305.5 | 65 | 1.2766 | 37 / 173.9 |
| A_ctrl1 | ad16_msg32_enc | 77 | 361.9 | 77 | 1.2766 | 37 / 173.9 |
| A_ctrl1 | ad16_msg32_dec | 77 | 361.9 | 77 | 1.2766 | 37 / 173.9 |
| A_ctrl1 | ad16_msg1024_enc | 821 | 3858.7 | 821 | 1.2766 | 37 / 173.9 |
| A_ctrl1 | ad16_msg1024_dec | 821 | 3858.7 | 821 | 1.2766 | 37 / 173.9 |
| A_ctrl1 | ad16_msg4096_enc | 3125 | 14687.5 | 3125 | 1.2766 | 37 / 173.9 |
| A_ctrl1 | ad16_msg4096_dec | 3125 | 14687.5 | 3125 | 1.2766 | 37 / 173.9 |
| A_ctrl2 | ad0_msg0_enc | 34 | 146.2 | 34 | 1.3953 | - |
| A_ctrl2 | ad0_msg0_dec | 34 | 146.2 | 34 | 1.3953 | - |
| A_ctrl2 | ad0_msg16_enc | 45 | 193.5 | 45 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad0_msg16_dec | 45 | 193.5 | 45 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad0_msg32_enc | 57 | 245.1 | 57 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad0_msg32_dec | 57 | 245.1 | 57 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad0_msg1024_enc | 801 | 3444.3 | 801 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad0_msg1024_dec | 801 | 3444.3 | 801 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad0_msg4096_enc | 3105 | 13351.5 | 3105 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad0_msg4096_dec | 3105 | 13351.5 | 3105 | 1.3953 | 17 / 73.1 |
| A_ctrl2 | ad16_msg0_enc | 54 | 232.2 | 54 | 1.3953 | - |
| A_ctrl2 | ad16_msg0_dec | 54 | 232.2 | 54 | 1.3953 | - |
| A_ctrl2 | ad16_msg16_enc | 65 | 279.5 | 65 | 1.3953 | 37 / 159.1 |
| A_ctrl2 | ad16_msg16_dec | 65 | 279.5 | 65 | 1.3953 | 37 / 159.1 |
| A_ctrl2 | ad16_msg32_enc | 77 | 331.1 | 77 | 1.3953 | 37 / 159.1 |
| A_ctrl2 | ad16_msg32_dec | 77 | 331.1 | 77 | 1.3953 | 37 / 159.1 |
| A_ctrl2 | ad16_msg1024_enc | 821 | 3530.3 | 821 | 1.3953 | 37 / 159.1 |
| A_ctrl2 | ad16_msg1024_dec | 821 | 3530.3 | 821 | 1.3953 | 37 / 159.1 |
| A_ctrl2 | ad16_msg4096_enc | 3125 | 13437.5 | 3125 | 1.3953 | 37 / 159.1 |
| A_ctrl2 | ad16_msg4096_dec | 3125 | 13437.5 | 3125 | 1.3953 | 37 / 159.1 |
| B_2stage | ad0_msg0_enc | 58 | 359.6 | 34 | 0.5673 | - |
| B_2stage | ad0_msg0_dec | 58 | 359.6 | 34 | 0.5673 | - |
| B_2stage | ad0_msg16_enc | 77 | 477.4 | 45 | 0.5656 | 29 / 179.8 |
| B_2stage | ad0_msg16_dec | 77 | 477.4 | 45 | 0.5656 | 29 / 179.8 |
| B_2stage | ad0_msg32_enc | 97 | 601.4 | 57 | 0.5687 | 29 / 179.8 |
| B_2stage | ad0_msg32_dec | 97 | 601.4 | 57 | 0.5687 | 29 / 179.8 |
| B_2stage | ad0_msg1024_enc | 1337 | 8289.4 | 801 | 0.5798 | 29 / 179.8 |
| B_2stage | ad0_msg1024_dec | 1337 | 8289.4 | 801 | 0.5798 | 29 / 179.8 |
| B_2stage | ad0_msg4096_enc | 5177 | 32097.4 | 3105 | 0.5804 | 29 / 179.8 |
| B_2stage | ad0_msg4096_dec | 5177 | 32097.4 | 3105 | 0.5804 | 29 / 179.8 |
| B_2stage | ad16_msg0_enc | 94 | 582.8 | 54 | 0.5559 | - |
| B_2stage | ad16_msg0_dec | 94 | 582.8 | 54 | 0.5559 | - |
| B_2stage | ad16_msg16_enc | 113 | 700.6 | 65 | 0.5567 | 65 / 403.0 |
| B_2stage | ad16_msg16_dec | 113 | 700.6 | 65 | 0.5567 | 65 / 403.0 |
| B_2stage | ad16_msg32_enc | 133 | 824.6 | 77 | 0.5603 | 65 / 403.0 |
| B_2stage | ad16_msg32_dec | 133 | 824.6 | 77 | 0.5603 | 65 / 403.0 |
| B_2stage | ad16_msg1024_enc | 1373 | 8512.6 | 821 | 0.5787 | 65 / 403.0 |
| B_2stage | ad16_msg1024_dec | 1373 | 8512.6 | 821 | 0.5787 | 65 / 403.0 |
| B_2stage | ad16_msg4096_enc | 5213 | 32320.6 | 3125 | 0.5801 | 65 / 403.0 |
| B_2stage | ad16_msg4096_dec | 5213 | 32320.6 | 3125 | 0.5801 | 65 / 403.0 |
| C_3stage | ad0_msg0_enc | 82 | 520.7 | 34 | 0.3918 | - |
| C_3stage | ad0_msg0_dec | 82 | 520.7 | 34 | 0.3918 | - |
| C_3stage | ad0_msg16_enc | 109 | 692.15 | 45 | 0.3901 | 41 / 260.35 |
| C_3stage | ad0_msg16_dec | 109 | 692.15 | 45 | 0.3901 | 41 / 260.35 |
| C_3stage | ad0_msg32_enc | 137 | 869.95 | 57 | 0.3931 | 41 / 260.35 |
| C_3stage | ad0_msg32_dec | 137 | 869.95 | 57 | 0.3931 | 41 / 260.35 |
| C_3stage | ad0_msg1024_enc | 1873 | 11893.55 | 801 | 0.4041 | 41 / 260.35 |
| C_3stage | ad0_msg1024_dec | 1873 | 11893.55 | 801 | 0.4041 | 41 / 260.35 |
| C_3stage | ad0_msg4096_enc | 7249 | 46031.15 | 3105 | 0.4047 | 41 / 260.35 |
| C_3stage | ad0_msg4096_dec | 7249 | 46031.15 | 3105 | 0.4047 | 41 / 260.35 |
| C_3stage | ad16_msg0_enc | 134 | 850.9 | 54 | 0.3808 | - |
| C_3stage | ad16_msg0_dec | 134 | 850.9 | 54 | 0.3808 | - |
| C_3stage | ad16_msg16_enc | 161 | 1022.35 | 65 | 0.3815 | 93 / 590.55 |
| C_3stage | ad16_msg16_dec | 161 | 1022.35 | 65 | 0.3815 | 93 / 590.55 |
| C_3stage | ad16_msg32_enc | 189 | 1200.15 | 77 | 0.385 | 93 / 590.55 |
| C_3stage | ad16_msg32_dec | 189 | 1200.15 | 77 | 0.385 | 93 / 590.55 |
| C_3stage | ad16_msg1024_enc | 1925 | 12223.75 | 821 | 0.403 | 93 / 590.55 |
| C_3stage | ad16_msg1024_dec | 1925 | 12223.75 | 821 | 0.403 | 93 / 590.55 |
| C_3stage | ad16_msg4096_enc | 7301 | 46361.35 | 3125 | 0.4044 | 93 / 590.55 |
| C_3stage | ad16_msg4096_dec | 7301 | 46361.35 | 3125 | 0.4044 | 93 / 590.55 |
| D | ad0_msg0_enc | 58 | 261.0 | 34 | 0.7816 | - |
| D | ad0_msg0_dec | 58 | 261.0 | 34 | 0.7816 | - |
| D | ad0_msg16_enc | 77 | 346.5 | 45 | 0.7792 | 29 / 130.5 |
| D | ad0_msg16_dec | 77 | 346.5 | 45 | 0.7792 | 29 / 130.5 |
| D | ad0_msg32_enc | 97 | 436.5 | 57 | 0.7835 | 29 / 130.5 |
| D | ad0_msg32_dec | 97 | 436.5 | 57 | 0.7835 | 29 / 130.5 |
| D | ad0_msg1024_enc | 1337 | 6016.5 | 801 | 0.7988 | 29 / 130.5 |
| D | ad0_msg1024_dec | 1337 | 6016.5 | 801 | 0.7988 | 29 / 130.5 |
| D | ad0_msg4096_enc | 5177 | 23296.5 | 3105 | 0.7997 | 29 / 130.5 |
| D | ad0_msg4096_dec | 5177 | 23296.5 | 3105 | 0.7997 | 29 / 130.5 |
| D | ad16_msg0_enc | 94 | 423.0 | 54 | 0.766 | - |
| D | ad16_msg0_dec | 94 | 423.0 | 54 | 0.766 | - |
| D | ad16_msg16_enc | 113 | 508.5 | 65 | 0.767 | 65 / 292.5 |
| D | ad16_msg16_dec | 113 | 508.5 | 65 | 0.767 | 65 / 292.5 |
| D | ad16_msg32_enc | 133 | 598.5 | 77 | 0.7719 | 65 / 292.5 |
| D | ad16_msg32_dec | 133 | 598.5 | 77 | 0.7719 | 65 / 292.5 |
| D | ad16_msg1024_enc | 1373 | 6178.5 | 821 | 0.7973 | 65 / 292.5 |
| D | ad16_msg1024_dec | 1373 | 6178.5 | 821 | 0.7973 | 65 / 292.5 |
| D | ad16_msg4096_enc | 5213 | 23458.5 | 3125 | 0.7993 | 65 / 292.5 |
| D | ad16_msg4096_dec | 5213 | 23458.5 | 3125 | 0.7993 | 65 / 292.5 |

## Stalled-interface cycles (fixed-seed random gaps and stalls; not architectural)

| Variant | Workload | Cycles |
|---|---|---|
| A | ad0_msg1024_enc | 851 |
| A | ad0_msg1024_dec | 845 |
| A | ad16_msg4096_enc | 3347 |
| A_ctrl1 | ad0_msg1024_enc | 851 |
| A_ctrl1 | ad0_msg1024_dec | 845 |
| A_ctrl1 | ad16_msg4096_enc | 3347 |
| A_ctrl2 | ad0_msg1024_enc | 851 |
| A_ctrl2 | ad0_msg1024_dec | 845 |
| A_ctrl2 | ad16_msg4096_enc | 3347 |
| B_2stage | ad0_msg1024_enc | 1385 |
| B_2stage | ad0_msg1024_dec | 1412 |
| B_2stage | ad16_msg4096_enc | 5432 |
| C_3stage | ad0_msg1024_enc | 1928 |
| C_3stage | ad0_msg1024_dec | 1923 |
| C_3stage | ad16_msg4096_enc | 7526 |
| D | ad0_msg1024_enc | 1385 |
| D | ad0_msg1024_dec | 1412 |
| D | ad16_msg4096_enc | 5432 |

## Worst path per category at the passing period (default strategy)

### A at 6.0 ns

| Category | Slack ns | Levels | Logic ns | Route ns | Skew ns | Max net pins | Endpoints |
|---|---|---|---|---|---|---|---|
| input_decode | 0.029 | 6 | 1.200 | 4.497 | -0.033 | 97 | `in_keep_reg[0]/C` → `core_u/state_reg_reg[260]/CE` |
| ctrl_to_state | 0.564 | 3 | 1.056 | 4.101 | -0.038 | 136 | `core_u/controller_state_reg[0]_rep/C` → `core_u/state_reg_reg[260]/CE` |
| authenticate | 0.828 | 13 | 2.835 | 2.293 | -0.037 | 4 | `core_u/tag_reg_reg[4]/C` → `core_u/discard_reg_reg/D` |
| perm_done | 0.840 | 3 | 1.029 | 3.863 | -0.028 | 129 | `core_u/permutation_u/done_reg_reg/C` → `core_u/state_reg_reg[118]/CE` |
| to_harness | 0.974 | 4 | 1.169 | 3.715 | -0.045 | 104 | `core_u/controller_state_reg[2]/C` → `in_keep_reg[0]/D` |
| ctrl_to_output | 1.295 | 2 | 0.704 | 3.724 | -0.037 | 129 | `core_u/controller_state_reg[2]_rep/C` → `core_u/tag_reg_reg[116]/CE` |
| ctrl_to_perm | 1.346 | 1 | 0.580 | 3.797 | -0.037 | 321 | `core_u/controller_state_reg[1]/C` → `core_u/permutation_u/state_reg_reg[177]/CE` |
| perm_control | 1.475 | 1 | 0.642 | 3.852 | -0.027 | 110 | `core_u/permutation_u/busy_reg_reg_rep__0/C` → `core_u/permutation_u/state_reg_reg[183]/D` |
| perm_capture | 1.987 | 2 | 0.766 | 3.206 | -0.037 | 10 | `core_u/permutation_u/state_reg_reg[243]/C` → `core_u/state_reg_reg[243]/D` |
| perm_round | 2.118 | 2 | 0.704 | 3.135 | -0.039 | 8 | `core_u/permutation_u/state_reg_reg[261]/C` → `core_u/permutation_u/state_reg_reg[244]/D` |
| finalize_tag | 2.506 | 1 | 0.606 | 2.890 | -0.037 | 10 | `core_u/permutation_u/state_reg_reg[236]/C` → `core_u/tag_reg_reg[44]/D` |
| perm_load | 2.884 | 1 | 0.580 | 2.533 | -0.047 | 5 | `core_u/state_reg_reg[60]/C` → `core_u/permutation_u/state_reg_reg[60]/D` |
| absorb_output | 2.911 | 1 | 0.580 | 2.335 | -0.030 | 6 | `core_u/state_reg_reg[72]/C` → `core_u/out_data_reg_reg[72]/D` |

### A_ctrl1 at 4.7 ns

| Category | Slack ns | Levels | Logic ns | Route ns | Skew ns | Max net pins | Endpoints |
|---|---|---|---|---|---|---|---|
| ctrl_to_state | 0.047 | 4 | 1.014 | 3.357 | -0.041 | 129 | `core_u/FSM_sequential_controller_state_reg[3]/C` → `core_u/state_reg_reg[134]/CE` |
| to_harness | 0.183 | 3 | 0.890 | 3.144 | -0.019 | 76 | `core_u/FSM_sequential_controller_state_reg[0]/C` → `in_keep_reg[8]/S` |
| ctrl_to_perm | 0.195 | 3 | 0.916 | 3.116 | -0.025 | 145 | `core_u/FSM_sequential_controller_state_reg[3]/C` → `core_u/permutation_u/round_constant[-1111111108]/CE` |
| authenticate | 0.233 | 13 | 2.906 | 1.566 | -0.041 | 4 | `core_u/tag_reg_reg[17]/C` → `core_u/discard_reg_reg/D` |
| input_decode | 0.240 | 13 | 2.751 | 1.713 | -0.042 | 7 | `in_data_reg[78]/C` → `core_u/discard_reg_reg/D` |
| ctrl_to_output | 0.275 | 1 | 0.580 | 3.924 | 0.038 | 119 | `core_u/FSM_sequential_controller_state_reg[4]/C` → `core_u/out_data_reg_reg[29]/D` |
| perm_control | 0.523 | 1 | 0.580 | 3.555 | -0.035 | 110 | `core_u/permutation_u/busy_reg_reg_rep/C` → `core_u/permutation_u/state_reg_reg[281]/D` |
| perm_round | 0.670 | 2 | 0.704 | 3.282 | -0.038 | 10 | `core_u/permutation_u/state_reg_reg[200]/C` → `core_u/permutation_u/state_reg_reg[247]/D` |
| perm_done | 0.684 | 2 | 0.766 | 2.968 | -0.042 | 10 | `core_u/permutation_u/done_reg_reg/C` → `core_u/FSM_sequential_controller_state_reg[1]_rep__0/CE` |
| finalize_tag | 1.200 | 1 | 0.799 | 2.731 | -0.052 | 5 | `core_u/key_reg_reg[27]/C` → `core_u/tag_reg_reg[27]/D` |
| perm_capture | 1.257 | 3 | 1.024 | 2.392 | -0.024 | 9 | `core_u/permutation_u/state_reg_reg[319]/C` → `core_u/state_reg_reg[319]/D` |
| absorb_output | 2.010 | 1 | 0.642 | 2.122 | 0.031 | 4 | `core_u/state_reg_reg[7]/C` → `core_u/out_data_reg_reg[7]/D` |
| perm_load | 2.016 | 1 | 0.642 | 1.914 | -0.122 | 4 | `core_u/state_reg_reg[45]/C` → `core_u/permutation_u/state_reg_reg[45]/D` |

### A_ctrl2 at 4.3 ns

| Category | Slack ns | Levels | Logic ns | Route ns | Skew ns | Max net pins | Endpoints |
|---|---|---|---|---|---|---|---|
| authenticate | 0.156 | 5 | 1.214 | 2.925 | -0.046 | 4 | `core_u/tag_reg_reg[69]/C` → `core_u/auth_ok_reg_reg/D` |
| input_decode | 0.169 | 5 | 1.211 | 2.921 | -0.040 | 10 | `in_data_reg[120]/C` → `core_u/auth_ok_reg_reg/D` |
| ctrl_to_state | 0.259 | 2 | 0.842 | 2.900 | -0.058 | 130 | `core_u/FSM_onehot_controller_state_reg[14]/C` → `core_u/state_reg_reg[112]/CE` |
| to_harness | 0.329 | 1 | 0.580 | 3.484 | 0.050 | 134 | `core_u/out_valid_reg_reg/C` → `signature_reg[84]/D` |
| perm_done | 0.350 | 1 | 0.580 | 3.075 | -0.055 | 129 | `core_u/permutation_u/done_reg_reg/C` → `core_u/state_reg_reg[112]/CE` |
| ctrl_to_output | 0.380 | 1 | 0.642 | 3.327 | 0.055 | 105 | `core_u/FSM_onehot_controller_state_reg[6]_rep/C` → `core_u/out_data_reg_reg[125]/D` |
| perm_control | 0.384 | 1 | 0.580 | 3.029 | -0.303 | 110 | `core_u/permutation_u/busy_reg_reg_rep/C` → `core_u/permutation_u/state_reg_reg[10]/D` |
| ctrl_to_perm | 0.495 | 1 | 0.580 | 3.038 | 0.054 | 321 | `core_u/FSM_onehot_controller_state_reg[7]/C` → `core_u/permutation_u/state_reg_reg[182]/CE` |
| perm_round | 0.495 | 2 | 0.704 | 2.795 | -0.302 | 8 | `core_u/permutation_u/state_reg_reg[256]/C` → `core_u/permutation_u/state_reg_reg[45]/D` |
| perm_capture | 1.201 | 3 | 0.828 | 2.014 | -0.299 | 7 | `core_u/permutation_u/state_reg_reg[104]/C` → `core_u/state_reg_reg[104]/D` |
| finalize_tag | 1.563 | 1 | 0.744 | 2.035 | -0.040 | 4 | `core_u/key_reg_reg[121]/C` → `core_u/tag_reg_reg[121]/D` |
| absorb_output | 1.716 | 1 | 0.608 | 1.756 | 0.064 | 4 | `core_u/state_reg_reg[33]/C` → `core_u/out_data_reg_reg[33]/D` |
| perm_load | 1.724 | 1 | 0.580 | 2.052 | 0.061 | 4 | `core_u/state_reg_reg[25]/C` → `core_u/permutation_u/state_reg_reg[25]/D` |

### B_2stage at 6.2 ns

| Category | Slack ns | Levels | Logic ns | Route ns | Skew ns | Max net pins | Endpoints |
|---|---|---|---|---|---|---|---|
| input_decode | 0.057 | 6 | 1.200 | 4.689 | -0.050 | 129 | `in_keep_reg[2]/C` → `core_u/state_reg_reg[170]/CE` |
| authenticate | 0.880 | 13 | 2.872 | 2.336 | -0.037 | 4 | `core_u/tag_reg_reg[1]/C` → `core_u/auth_ok_reg_reg/D` |
| ctrl_to_state | 0.981 | 3 | 1.060 | 4.203 | 0.051 | 333 | `core_u/controller_state_reg[1]/C` → `core_u/state_reg_reg[141]/D` |
| to_harness | 1.019 | 4 | 0.952 | 4.109 | -0.024 | 282 | `core_u/controller_state_reg[3]/C` → `in_keep_reg[0]/D` |
| perm_control | 1.058 | 1 | 0.580 | 4.509 | -0.047 | 112 | `core_u/permutation_u/busy_reg_reg_rep__0/C` → `core_u/permutation_u/state_reg_reg[152]/D` |
| ctrl_to_output | 1.285 | 2 | 0.766 | 3.859 | -0.050 | 129 | `core_u/controller_state_reg[4]_rep/C` → `core_u/tag_reg_reg[108]/CE` |
| perm_done | 1.353 | 3 | 0.828 | 3.740 | -0.038 | 129 | `core_u/permutation_u/done_reg_reg/C` → `core_u/state_reg_reg[121]/CE` |
| ctrl_to_perm | 1.538 | 2 | 0.704 | 3.724 | -0.132 | 333 | `core_u/controller_state_reg[1]/C` → `core_u/permutation_u/round_constant[-1111111109]/D` |
| perm_capture | 1.996 | 3 | 1.058 | 3.108 | -0.032 | 9 | `core_u/permutation_u/state_reg_reg[0]/C` → `core_u/state_reg_reg[0]/D` |
| perm_round | 2.816 | 1 | 0.580 | 2.735 | -0.112 | 8 | `core_u/permutation_u/state_reg_reg[300]/C` → `core_u/permutation_u/sbox_reg_reg[44]/D` |
| perm_load | 2.874 | 1 | 0.642 | 2.541 | -0.136 | 5 | `core_u/state_reg_reg[23]/C` → `core_u/permutation_u/state_reg_reg[23]/D` |
| absorb_output | 2.920 | 1 | 0.580 | 2.651 | -0.045 | 5 | `core_u/state_reg_reg[27]/C` → `core_u/out_data_reg_reg[27]/D` |
| finalize_tag | 3.207 | 1 | 0.580 | 2.370 | -0.036 | 8 | `core_u/permutation_u/state_reg_reg[296]/C` → `core_u/tag_reg_reg[104]/D` |

### C_3stage at 6.35 ns

| Category | Slack ns | Levels | Logic ns | Route ns | Skew ns | Max net pins | Endpoints |
|---|---|---|---|---|---|---|---|
| input_decode | 0.201 | 6 | 1.200 | 4.669 | -0.039 | 129 | `in_keep_reg[6]/C` → `core_u/state_reg_reg[25]/CE` |
| authenticate | 0.634 | 13 | 2.827 | 2.588 | -0.048 | 4 | `core_u/tag_reg_reg[3]/C` → `core_u/auth_ok_reg_reg/D` |
| ctrl_to_state | 0.902 | 3 | 1.142 | 4.309 | -0.041 | 111 | `core_u/controller_state_reg[1]_rep__0/C` → `core_u/state_reg_reg[69]/D` |
| ctrl_to_perm | 0.986 | 2 | 0.766 | 4.310 | -0.048 | 321 | `core_u/controller_state_reg[1]/C` → `core_u/permutation_u/state_reg_reg[211]/CE` |
| perm_control | 1.036 | 1 | 0.642 | 4.635 | -0.033 | 339 | `core_u/permutation_u/busy_reg_reg/C` → `core_u/permutation_u/state_reg_reg[39]/D` |
| perm_done | 1.062 | 3 | 0.828 | 4.174 | -0.046 | 129 | `core_u/permutation_u/done_reg_reg/C` → `core_u/state_reg_reg[234]/CE` |
| to_harness | 1.272 | 4 | 1.188 | 3.746 | -0.042 | 112 | `core_u/controller_state_reg[4]_rep/C` → `in_keep_reg[0]/D` |
| ctrl_to_output | 1.485 | 3 | 1.149 | 3.420 | -0.044 | 111 | `core_u/controller_state_reg[1]_rep__0/C` → `core_u/auth_ok_reg_reg/D` |
| perm_capture | 1.819 | 3 | 1.060 | 3.434 | -0.034 | 6 | `core_u/permutation_u/state_reg_reg[0]/C` → `core_u/state_reg_reg[0]/D` |
| finalize_tag | 2.883 | 1 | 0.642 | 2.786 | -0.035 | 7 | `core_u/permutation_u/state_reg_reg[254]/C` → `core_u/tag_reg_reg[62]/D` |
| absorb_output | 3.057 | 1 | 0.580 | 2.592 | -0.042 | 6 | `core_u/state_reg_reg[48]/C` → `core_u/out_data_reg_reg[48]/D` |
| perm_load | 3.251 | 1 | 0.642 | 2.414 | -0.038 | 5 | `core_u/state_reg_reg[69]/C` → `core_u/permutation_u/state_reg_reg[69]/D` |

### D at 4.5 ns

| Category | Slack ns | Levels | Logic ns | Route ns | Skew ns | Max net pins | Endpoints |
|---|---|---|---|---|---|---|---|
| input_decode | 0.055 | 4 | 1.014 | 3.166 | -0.025 | 34 | `in_keep_reg[0]/C` → `core_u/out_keep_reg_reg[0]/CE` |
| authenticate | 0.101 | 5 | 1.076 | 3.278 | -0.038 | 4 | `core_u/tag_reg_reg[68]/C` → `core_u/auth_ok_reg_reg/D` |
| ctrl_to_output | 0.150 | 4 | 0.952 | 3.036 | -0.121 | 313 | `core_u/FSM_onehot_controller_state_reg[6]/C` → `core_u/out_keep_reg_reg[0]/CE` |
| ctrl_to_state | 0.167 | 3 | 1.021 | 2.948 | -0.124 | 130 | `core_u/FSM_onehot_controller_state_reg[14]/C` → `core_u/state_reg_reg[149]/CE` |
| ctrl_to_perm | 0.203 | 2 | 0.900 | 3.108 | -0.049 | 321 | `core_u/FSM_onehot_controller_state_reg[11]/C` → `core_u/permutation_u/state_reg_reg[140]/CE` |
| perm_control | 0.345 | 2 | 0.704 | 3.085 | -0.125 | 321 | `core_u/permutation_u/busy_reg_reg/C` → `core_u/permutation_u/state_reg_reg[140]/CE` |
| to_harness | 0.492 | 3 | 0.890 | 2.579 | -0.299 | 155 | `core_u/FSM_onehot_controller_state_reg[5]/C` → `in_keep_reg[5]/CE` |
| perm_capture | 0.897 | 1 | 0.580 | 2.894 | -0.125 | 6 | `core_u/permutation_u/state_reg_reg[50]/C` → `core_u/state_reg_reg[50]/D` |
| perm_done | 0.912 | 2 | 0.766 | 2.536 | -0.045 | 129 | `core_u/permutation_u/done_reg_reg/C` → `core_u/state_reg_reg[149]/CE` |
| perm_round | 1.114 | 1 | 0.580 | 2.678 | -0.124 | 7 | `core_u/permutation_u/state_reg_reg[182]/C` → `core_u/permutation_u/sbox_reg_reg[182]/D` |
| finalize_tag | 1.183 | 1 | 0.580 | 2.607 | -0.125 | 9 | `core_u/permutation_u/state_reg_reg[244]/C` → `core_u/tag_reg_reg[52]/D` |
| perm_stage_out | 1.238 | 1 | 0.580 | 2.384 | -0.292 | 4 | `core_u/permutation_u/sbox_reg_reg[46]/C` → `core_u/permutation_u/state_reg_reg[27]/D` |
| absorb_output | 1.443 | 1 | 0.580 | 2.155 | -0.220 | 5 | `core_u/state_reg_reg[123]/C` → `core_u/out_data_reg_reg[123]/D` |
| perm_load | 1.637 | 1 | 0.580 | 2.321 | 0.042 | 3 | `core_u/state_reg_reg[241]/C` → `core_u/permutation_u/state_reg_reg[241]/D` |

