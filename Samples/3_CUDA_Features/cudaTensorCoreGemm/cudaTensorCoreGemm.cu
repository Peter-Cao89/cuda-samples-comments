/* Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

// CUDA sample demonstrating a GEMM computation using the Warp Matrix Multiply
// and Accumulate API introduced in CUDA 9.

// In this program, the compute_gemm kernel computes the result of a matrix
// multiplication and addition: D = alpha * A * B + beta * C. The dimensions of
// both C and D matrices are M_GLOBAL x N_GLOBAL. The A matrix is M_GLOBAL x
// K_GLOBAL (row-major), the B matrix is K_GLOBAL x N_GLOBAL (column-major). In
// that kernel, each CTA computes one 128 x 128 tile of the resulting matrix per
// iteration. When the tile is computed, the CTA stores it to the global memory
// and begins a new iteration, selecting a new 128 x 128 tile to compute.
// Each CTA consists of eight warps. For the 128 x 128 tile, each warp computes
// eight 16 x 16 subtiles, organized in a 2 x 4 two-dimensional array. Warps
// compute the 16 x 16 subtiles using nvcuda::wmma::mma_sync operations by
// moving through the K_GLOBAL dimension of the A and B matrices and
// accumulating the intermediate result in the local thread state.

// There are a number of simple optimizations used in the algorithm:
// - The CTA copies the 128 x 128 tile of the C matrix from the global memory to
//   shared memory. After that is done, each warp loads the C matrix fragments
//   from shared memory, thus avoiding a random global memory access.
// - On each internal iteration, the CTA copies a portion of the A and B
//   matrices from global memory to shared memory. After that, all warps in the
//   CTA reuse the A and B data from shared memory, thus reducing the number of
//   data copies from global memory.
// - The portions of the A and B matrices are stored in shared memory with an
//   additional padding (skew) to reduce the number of shared memory access bank
//   conflicts.
//   (See a detailed explanation near the SKEW_HALF macro definition.)
// - When the CTA finishes computing the tiles of the resulting matrix, each
//   warp stores its subtiles to shared memory. The CTA then copies the shared
//   memory contents to global memory, again avoiding redundant random global
//   memory  accesses.
// - Note that the CTA tile size is chosen to maximize the GPU register
//   utilization, but carefully enough to avoid local memory use.

#include <assert.h>
#include <cuda.h>
#include <mma.h>
#include <stdio.h>

// helper functions and utilities to work with CUDA
#include <helper_cuda.h>
#include <helper_functions.h>

// Externally configurable parameters.

#ifndef CPU_DEBUG
// Set this to 1 to verify the correctness of the GPU-computed matrix.
#define CPU_DEBUG 0
#endif

#ifndef SHARED_MEMORY_LIMIT_64K
// Set this to 0 to use more than 64 Kb of shared memory to cache data, to
// improve the performance of the computations on GPU.
// Note that you need a GPU that can have more than 64 Kb of shared memory
// per multiprocessor.
#define SHARED_MEMORY_LIMIT_64K 1
#endif

// GPU configuration.

#define WARP_SIZE 32

// MMA matrix tile dimensions.

#define M 16
#define N 16
#define K 16

#define WMMA_M 16
#define WMMA_N 16
#define WMMA_K 16

// GEMM configuration.

#define M_TILES 256   /* 矩阵A的全局tiles行数 */
#define N_TILES 256   /* 矩阵B的全局tiles列数 */
#define K_TILES 256   /* 矩阵A的全局tiles列数，矩阵B的全局tiles行数 */

#define M_GLOBAL (M * M_TILES)
#define N_GLOBAL (N * N_TILES)
#define K_GLOBAL (K * K_TILES)

#define C_LAYOUT wmma::mem_row_major

// Implementation constants.

#define WARPS_PER_BLOCK 8
#define THREADS_PER_BLOCK (WARP_SIZE * WARPS_PER_BLOCK)

#if SHARED_MEMORY_LIMIT_64K
// With only 64 Kb shared memory available, we can fit two 8-tile chunks of
// the A and B matrix data, that are 16 * 16 * 8 * 8 * 2 = 32 Kb each
// (i.e. two 8x8 arrays of tiles of 16x16 half-typed elements per CTA).
// But we cannot account the 8 Kb total skew overhead, without which the
// performance would be severely impacted. So we choose to reduce the chunk size
// in half, i.e. the amount of A and B matrix data we cache in shared memory.
// Accordingly, this doubles the number of outer iterations across the global K
// dimension, which only slightly impacts the performance.
#define CHUNK_K 4
#else
#define CHUNK_K 8
#endif

#define CHUNK_LINE_BYTES (CHUNK_K * K * sizeof(half))
#define WARP_COPY_BYTES (WARP_SIZE * sizeof(int4))
#define CHUNK_COPY_LINES_PER_WARP (WARP_COPY_BYTES / CHUNK_LINE_BYTES)
#define CHUNK_COPY_LINE_LANES (WARP_SIZE / CHUNK_COPY_LINES_PER_WARP)

#define BLOCK_ROW_WARPS 2
#define BLOCK_COL_WARPS 4

#define WARP_ROW_TILES 4
#define WARP_COL_TILES 2

#define BLOCK_ROW_TILES (WARP_ROW_TILES * BLOCK_ROW_WARPS)
#define BLOCK_COL_TILES (WARP_COL_TILES * BLOCK_COL_WARPS)

#define GLOBAL_MEM_STRIDE N_GLOBAL    // 矩阵C每行在全局内存中的stride，也就是一行的元素数量，16*256

#define SHMEM_STRIDE (N * BLOCK_ROW_TILES)    // 矩阵C的共享内存stride=16 * 8=128
#define SHMEM_OFFSET (N * WARP_ROW_TILES)

// The macro below is used to shift rows of the A matrix and columns of the B matrix
// in shared memory to minimize possible bank conflicts.
// Before performing the nvcuda::wmma::mma_sync operation, the warp must load the matrix
// data using the nvcuda::wmma::load_matrix_sync operation. Although the memory access pattern
// is not specified for that function, each lane in the warp can read one or multiple matrix
// elements from different matrix rows or columns.
// For shared memory, such access can result in bank conflicts if different rows / columns
// of the matrix map to the same bank. By shifting each row and column by a few bytes, we
// make sure that they map to different banks, thus reducing the number of possible bank
// conflicts.
// The number of 16 two-byte "half" elements is chosen as the minimum possible shift because
// we must keep each row and column 256-bit aligned, as required by nvcuda::wmma::load_matrix_sync.
#define SKEW_HALF 16

#define checkKernelErrors(expr)                             \
  do {                                                      \
    expr;                                                   \
                                                            \
    cudaError_t __err = cudaGetLastError();                 \
    if (__err != cudaSuccess) {                             \
      printf("Line %d: '%s' failed: %s\n", __LINE__, #expr, \
             cudaGetErrorString(__err));                    \
      abort();                                              \
    }                                                       \
  } while (0)

using namespace nvcuda;

__host__ void init_host_matrices(half *a, half *b, float *c) {
  for (int i = 0; i < M_GLOBAL; i++) {
    for (int j = 0; j < K_GLOBAL; j++) {
      a[i * K_GLOBAL + j] = (half)(rand() % 3);
    }
  }

  for (int i = 0; i < N_GLOBAL; i++) {
    for (int j = 0; j < K_GLOBAL; j++) {
      b[i * K_GLOBAL + j] = (half)(rand() % 3);
    }
  }

  for (int t = 0; t < M_GLOBAL * N_GLOBAL; t++) {
    c[t] = static_cast<float>(rand() % 3);
  }
}

__global__ void compute_gemm(const half *A, const half *B, const float *C,
                             float *D, float alpha, float beta) {
  extern __shared__ half shmem[][CHUNK_K * K + SKEW_HALF];

  // Warp and lane identification.
  const unsigned int warpId = threadIdx.x / WARP_SIZE;
  const unsigned int laneId = threadIdx.x % WARP_SIZE;

  // Offset in shared memory from which the B matrix is stored.
  // 因为在拷贝矩阵A与矩阵B时，共享内存的一半存放A一半存放B。所以要计算一下矩阵B在共享内存中的偏移地址
  const size_t shmem_idx_b_off = BLOCK_COL_TILES * M;

  // This pointer is used to access the C and D matrix tiles this warp computes.
  // 因为矩阵C与矩阵D元素类型都是float类型，因此一个block中的矩阵C的tiles占据64KB的共享内存
  // warpId/2是因为一个block中的8个warps，需要计算当前warp在block布局中第几行
  // 从warp为粒度的角度看，block的布局是一行2个warps一列4个warps;
  // 从fragments粒度的角度看，block中一行的布局是一行有8个fragments一列有2个fragments;
  // 从elements粒度的角度看，每个fragment中有16x16个元素
  // 因此，根据warps的布局，warp中一行有8*N=128个元素，一列有M*2(但是此处使用的是K*2,不知为何)。
  // 因此SHMEM_STRIDE为共享内存中矩阵C的存储stride为16*8;每行的offset为4*N，一个warp中每行有4个fragments
  float *shmem_warp_tile_ptr = (float *)&shmem[0][0] +
                               (warpId / 2) * SHMEM_STRIDE * M /* K */ * 2 +
                               (warpId % 2) * SHMEM_OFFSET;

  // This pointer is used to stream the C and D matrices block-wide tile to and
  // from shared memory.
  // 该指针是warp内共享内存的偏移计算，因为warp中每行有4个fragments，因此offset为N*4*2*M
  float *shmem_warp_stream_ptr =
      (float *)&shmem[0][0] + warpId * SHMEM_STRIDE * M /* K */;

  // Adjust the beta scaler, as it'll be multiplied by alpha at the end of
  // each tile computation. Technically this is not generally correct (may
  // result in a loss of precision). Zero still needs to be specially handled
  // though.
  beta /= alpha;

  // Each CTA slides along the 128 x 128 tiles from the top left corner of the
  // matrix to the right and down, and selects the next tile to compute. Once
  // there's no such tile, all warps in this CTA exit.
  for (unsigned int block_pos = blockIdx.x;; block_pos += gridDim.x) {
    // block_tile_i为tile在纵坐标方向索引，当前线程块负责的tile在全局内存中的行索引
    // block_pos是当前线程块的索引，BLOCK_ROW_TILES是每个线程块行方向上tiles的数量，N_TILES是矩阵全局tiles的列数
    // (block_pos * BLOCK_ROW_TILES): 将当前block为索引乘以每个block行方向tiles的数量，得到当前行方向上总tiles数量
    // ((block_pos * BLOCK_ROW_TILES) / N_TILES): 除以全局矩阵中总的tiles列数，得到当前块在行方向上的block行索引
    // 得到的block行索引乘以每个block列方向tiles数量，即为当前block中tiles索引的起始点
    const unsigned int block_tile_i = ((block_pos * BLOCK_ROW_TILES) / N_TILES) * (BLOCK_COL_TILES);
    // block_tile_j为矩阵B的tiles在横坐标方向的索引，当前线程块负责的tile在全局内存中列索引，
    // 这块的写法是否有误？理论上应该是(block_pos * BLOCK_ROW_TILES) % N_TILES
    const unsigned int block_tile_j = (block_pos * BLOCK_COL_TILES) % N_TILES;

    // Stop when there are no more D matrix tiles to compute in this CTA.
    if (block_tile_i >= M_TILES) {
      break;
    }

    // This warp's pointer to the C matrix data to copy memory from to shared
    // memory.
    // 虽然warp的逻辑布局是2*4个tiles，block的逻辑布局是4*2个warps
    // 但是按照代码的意思是在执行拷贝操作时一行看做一个warp，也就是8个tiles的一行看作一个warp进行数据加载
    // 因此，block_tile_i会加上warpId
    const size_t gmem_idx =
        (block_tile_i + warpId) * M * GLOBAL_MEM_STRIDE + block_tile_j * N;
    // gmem_idx为当前线程要拷贝tile的偏移起始点,将其赋值给src_gmem_warp_stream_ptr*(warp的stream拷贝的全局内存指针地址)
    const float *src_gmem_warp_stream_ptr = &C[gmem_idx];

    // Stream multiple C tiles to shared memory.
    // 将矩阵C的tiles流式的从全局内存拷贝到共享内存中,一个warp拷贝一行tiles(一行有8*16个元素，一共16行)，一共8行tiles
    // 从全局内存拷贝到共享内存，每个线程只能拷贝一个元素，但是一个warp有16行，因此需要循环16次，每次拷贝一行元素
    // 一行有16*8=128个float元素，但是一共只有32个线程，因此使用vectorized memory access的方式进行拷贝，拷贝类型设置为int4，这样一次性就可以拷贝完一行
    // tile内共享内存中一行的stride为16*8+128=SHMEM_STRIDE，全局内存的一行stride为16*256=GLOBAL_MEM_STRIDE
    // tile内每个线程的索引为laneId
#pragma unroll
    for (int i = 0; i < K; i++) {
      typedef int4 copy_t;

      *((copy_t *)(shmem_warp_stream_ptr + SHMEM_STRIDE * i) + laneId) =
          *((copy_t *)(src_gmem_warp_stream_ptr + GLOBAL_MEM_STRIDE * i) +
            laneId);
    }
    // 在共享内存进行写完之后执行一个barrier
    __syncthreads();

    // These fragments will accumulate the result of A and B matrix fragment
    // multiplications along the K_GLOBAL dimension.
    // 声明一个warp内fragment的数组，每个fragment是一个tile，一个warp中2行4列tiles
    wmma::fragment<wmma::accumulator, M, N, K, float> c[WARP_COL_TILES]
                                                       [WARP_ROW_TILES];

    // Load the C matrix tiles into fragments from shared memory.
    // 将每个warp内的矩阵C的tiles从共享内存加载到寄存器中。warp内执行模式的依然是SIMT，因为一个warp内有2行4列
    // 因此需要将逻辑布局转换为物理布局
#pragma unroll
    for (int i = 0; i < WARP_COL_TILES/* 2 */; i++) {
#pragma unroll
      for (int j = 0; j < WARP_ROW_TILES/* 4 */; j++) {
        const float *tile_ptr =  shmem_warp_tile_ptr + i * SHMEM_STRIDE * K + j * N;

        wmma::load_matrix_sync(c[i][j], tile_ptr, SHMEM_STRIDE, C_LAYOUT);
      }
    }

    __syncthreads();

    // Scale the C matrix.
#pragma unroll
    for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
      for (int j = 0; j < WARP_ROW_TILES; j++) {
#pragma unroll
        for (int t = 0; t < c[i][j].num_elements; t++) {
          c[i][j].x[t] *= beta;
        }
      }
    }

    // Select what warp copies what matrix to shared memory.
    // Warps 0-3 copy the A matrix, warps 4-7 copy the B matrix.
    const half *warp_ptr = (warpId < 4) ? (&A[block_tile_i * M * K_GLOBAL] +
                                           M * K_GLOBAL * (warpId % 4) * 2)
                                        : (&B[block_tile_j * N * K_GLOBAL] +
                                           N * K_GLOBAL * (warpId % 4) * 2);

    // Go through the global K dimension by a fixed step at a time.
#pragma unroll
    for (int tile_k = 0; tile_k < K_TILES; tile_k += CHUNK_K) {
      // Copy slices of the A and B matrices to shared memory.
      // The first half of the warps in the CTA copy the A matrix, the rest copy
      // the B matrix.
      size_t shmem_idx =
          warpId < (WARPS_PER_BLOCK / 2)
              ? (M * (warpId % (WARPS_PER_BLOCK / 2)) * 2)
              : (N * (warpId % (WARPS_PER_BLOCK / 2)) * 2 + shmem_idx_b_off);

      // First half of the warp copies the first row / column of the matrix,
      // the second half of the warp copies the next.
      int4 *lane_ptr = (int4 *)(warp_ptr + tile_k * K +
                                (laneId / CHUNK_COPY_LINE_LANES) * K_GLOBAL) +
                       (laneId % CHUNK_COPY_LINE_LANES);

      // Shift the second half of the warp to the next row / column in the
      // shared memory.
      shmem_idx += laneId / CHUNK_COPY_LINE_LANES;

#pragma unroll
      for (int i = 0; i < ((WARP_SIZE / 2) / CHUNK_COPY_LINES_PER_WARP) * 2;
           i++) {
        // Copy 16 bytes at once in each lane.
        *((int4 *)&shmem[shmem_idx][0] + (laneId % CHUNK_COPY_LINE_LANES)) =
            *lane_ptr;

        // Advance the global memory pointer and the shared memory index.
        lane_ptr =
            (int4 *)((half *)lane_ptr + K_GLOBAL * CHUNK_COPY_LINES_PER_WARP);
        shmem_idx += CHUNK_COPY_LINES_PER_WARP;
      }

      __syncthreads();

      // Compute a grid of C matrix tiles in each warp.
#pragma unroll
      for (int k_step = 0; k_step < CHUNK_K; k_step++) {
        wmma::fragment<wmma::matrix_a, M, N, K, half, wmma::row_major>
            a[WARP_COL_TILES];
        wmma::fragment<wmma::matrix_b, M, N, K, half, wmma::col_major>
            b[WARP_ROW_TILES];

#pragma unroll
        for (int i = 0; i < WARP_COL_TILES; i++) {
          size_t shmem_idx_a = (warpId / 2) * M * 2 + (i * M);
          const half *tile_ptr = &shmem[shmem_idx_a][k_step * K];

          wmma::load_matrix_sync(a[i], tile_ptr, K * CHUNK_K + SKEW_HALF);

#pragma unroll
          for (int j = 0; j < WARP_ROW_TILES; j++) {
            if (i == 0) {
              // Load the B matrix fragment once, because it is going to be
              // reused against the other A matrix fragments.
              size_t shmem_idx_b = shmem_idx_b_off +
                                   (WARP_ROW_TILES * N) * (warpId % 2) +
                                   (j * N);
              const half *tile_ptr = &shmem[shmem_idx_b][k_step * K];

              wmma::load_matrix_sync(b[j], tile_ptr, K * CHUNK_K + SKEW_HALF);
            }

            wmma::mma_sync(c[i][j], a[i], b[j], c[i][j]);
          }
        }
      }

      __syncthreads();
    }

      // Store the D fragments to shared memory.
#pragma unroll
    for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
      for (int j = 0; j < WARP_ROW_TILES; j++) {
#pragma unroll
        // Uniform, point-wise transformations of ALL fragment elements by ALL
        // threads in the warp are well-defined even though element indices
        // within fragment storage are not defined.
        for (int t = 0; t < c[i][j].num_elements; t++) c[i][j].x[t] *= alpha;

        float *tile_ptr = shmem_warp_tile_ptr + i * SHMEM_STRIDE * K + j * N;

        wmma::store_matrix_sync(tile_ptr, c[i][j], SHMEM_STRIDE, C_LAYOUT);
      }
    }

    __syncthreads();

    // Now that shared memory contains all the D tiles, stream them to global
    // memory.
    float *dst_gmem_warp_stream_ptr = &D[gmem_idx];

#pragma unroll
    for (int i = 0; i < K; i++) {
      *((int4 *)(dst_gmem_warp_stream_ptr + GLOBAL_MEM_STRIDE * i) + laneId) =
          *((int4 *)(shmem_warp_stream_ptr + SHMEM_STRIDE * i) + laneId);
    }

    __syncthreads();
  }
}

// Performs an MxNxK GEMM (C=alpha*A*B + beta*C) assuming:
//  1) Matrices are packed in memory.
//  2) M, N and K are multiples of 16.
//  3) Neither A nor B are transposed.
// Note: This is a less performant version of the compute_gemm kernel. It is
// designed for
//       demonstration purposes only to show the CUDA WMMA API use without
//       relying on availability of the shared memory.
__global__ void simple_wmma_gemm(half *a, half *b, float *c, float *d, int m_ld,
                                 int n_ld, int k_ld, float alpha, float beta) {
  // Leading dimensions. Packed with no transpositions.
  int lda = k_ld;
  int ldb = k_ld;
  int ldc = n_ld;

  // Tile using a 2D grid
  int warpM = (blockIdx.x * blockDim.x + threadIdx.x) / warpSize;
  int warpN = (blockIdx.y * blockDim.y + threadIdx.y);

  // Declare the fragments
  wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, wmma::row_major>
      a_frag;
  wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, wmma::col_major>
      b_frag;
  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, float> acc_frag;
  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, float> c_frag;

  wmma::fill_fragment(acc_frag, 0.0f);

  // Loop over k
  for (int i = 0; i < k_ld; i += WMMA_K) {
    int aCol = i;
    int aRow = warpM * WMMA_M;
    int bCol = warpN * N;
    int bRow = i;

    // Bounds checking
    if (aRow < m_ld && aCol < k_ld && bRow < k_ld && bCol < n_ld) {
      // Load the inputs
      wmma::load_matrix_sync(a_frag, a + aCol + aRow * lda, lda);
      wmma::load_matrix_sync(b_frag, b + bRow + bCol * ldb, ldb);

      // Perform the matrix multiplication
      wmma::mma_sync(acc_frag, a_frag, b_frag, acc_frag);
    }
  }

  // Load in the current value of c, scale it by beta, and add this our result
  // scaled by alpha
  int cCol = warpN * WMMA_N;
  int cRow = warpM * WMMA_M;

  if (cRow < m_ld && cCol < n_ld) {
    wmma::load_matrix_sync(c_frag, c + cCol + cRow * ldc, ldc,
                           wmma::mem_row_major);

    for (int i = 0; i < c_frag.num_elements; i++) {
      c_frag.x[i] = alpha * acc_frag.x[i] + beta * c_frag.x[i];
    }

    // Store the output
    wmma::store_matrix_sync(d + cCol + cRow * ldc, c_frag, ldc,
                            wmma::mem_row_major);
  }
}

__host__ void matMultiplyOnHost(half *A, half *B, float *C, float alpha,
                                float beta, int numARows, int numAColumns,
                                int numBRows, int numBColumns, int numCRows,
                                int numCColumns) {
  for (int i = 0; i < numCRows; i++) {
    for (int j = 0; j < numCColumns; j++) {
      float temp = 0.0;

      for (int k = 0; k < numAColumns; k++) {
        temp += (float)A[i * numAColumns + k] * (float)B[j * numBRows + k];
      }

      C[i * numCColumns + j] = temp * alpha + beta * C[i * numCColumns + j];
    }
  }
}

int main(int argc, char **argv) {
  printf("Initializing...\n");

  int dev = findCudaDevice(argc, (const char **)argv);

  cudaDeviceProp deviceProp;
  checkCudaErrors(cudaGetDeviceProperties(&deviceProp, dev));

  // Tensor cores require a GPU of Volta (SM7X) architecture or higher.
  if (deviceProp.major < 7) {
    printf(
        "cudaTensorCoreGemm requires SM 7.0 or higher to use Tensor "
        "Cores.  Exiting...\n");
    exit(EXIT_WAIVED);
  }

  printf("M: %d (%d x %d)\n", M_GLOBAL, M, M_TILES);
  printf("N: %d (%d x %d)\n", N_GLOBAL, N, N_TILES);
  printf("K: %d (%d x %d)\n", K_GLOBAL, K, K_TILES);

  half *A_h = NULL;
  half *B_h = NULL;
  float *C_h = NULL;
#if CPU_DEBUG
  float *result_hD = NULL;
  float *result_host = NULL;
#endif

  A_h = (half *)malloc(sizeof(half) * M_GLOBAL * K_GLOBAL);
  B_h = (half *)malloc(sizeof(half) * K_GLOBAL * N_GLOBAL);
  C_h = (float *)malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
#if CPU_DEBUG
  result_hD = (float *)malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
  result_host = (float *)malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
#endif

  half *A = NULL;
  half *B = NULL;
  float *C = NULL;
  float *D = NULL;

  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&A),
                             sizeof(half) * M_GLOBAL * K_GLOBAL));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&B),
                             sizeof(half) * N_GLOBAL * K_GLOBAL));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&C),
                             sizeof(float) * M_GLOBAL * N_GLOBAL));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&D),
                             sizeof(float) * M_GLOBAL * N_GLOBAL));

  assert(((unsigned long long)A) % 128 == 0);
  assert(((unsigned long long)B) % 128 == 0);
  assert(((unsigned long long)C) % 128 == 0);
  assert(((unsigned long long)D) % 128 == 0);

  init_host_matrices(A_h, B_h, C_h);

  printf("Preparing data for GPU...\n");

  checkCudaErrors(cudaMemcpy(A, A_h, sizeof(half) * M_GLOBAL * K_GLOBAL,
                             cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(B, B_h, sizeof(half) * N_GLOBAL * K_GLOBAL,
                             cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(C, C_h, sizeof(float) * M_GLOBAL * N_GLOBAL,
                             cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemset(D, 0, sizeof(float) * M_GLOBAL * N_GLOBAL));

  enum {
    // Compute the right amount of shared memory to request.
    // We need shared memory to hold per-CTA C and D matrix tiles, and to cache
    // per-CTA chunks
    // of the A and B matrices. Therefore, the right amount to request is the
    // maximum of those
    // two numbers.
    SHMEM_SZ = MAX(
        sizeof(half) * (BLOCK_COL_TILES * M) * (CHUNK_K * K + SKEW_HALF) * 2,
        M * (BLOCK_ROW_WARPS * WARP_ROW_TILES) * N *
            (BLOCK_COL_WARPS * WARP_COL_TILES) * sizeof(float))
  };

  printf("Required shared memory size: %lu Kb\n", SHMEM_SZ / 1024UL);

  const float alpha = 1.1f;
  const float beta = 1.2f;

  cudaEvent_t start, stop;

  checkCudaErrors(cudaEventCreate(&start));
  checkCudaErrors(cudaEventCreate(&stop));
  checkCudaErrors(cudaEventRecord(start));

  // If enough shared memory available on the GPU use high performant kernel
  if (deviceProp.sharedMemPerMultiprocessor >= SHMEM_SZ) {
    printf("Computing... using high performance kernel compute_gemm \n");

    checkCudaErrors(cudaFuncSetAttribute(
        compute_gemm, cudaFuncAttributeMaxDynamicSharedMemorySize, SHMEM_SZ));
    checkKernelErrors(
        (compute_gemm<<<deviceProp.multiProcessorCount, THREADS_PER_BLOCK,
                        SHMEM_SZ>>>(A, B, C, D, alpha, beta)));
#if CPU_DEBUG
    checkCudaErrors(cudaMemcpy(result_hD, D,
                               sizeof(float) * M_GLOBAL * N_GLOBAL,
                               cudaMemcpyDeviceToHost));
#endif
  } else {
    dim3 gridDim;
    dim3 blockDim;

    // blockDim.x must be a multple of warpSize
    // 128x4 means we have 16 warps and a block computes a 64x64 output tile
    blockDim.x = 128;
    blockDim.y = 4;

    gridDim.x = (M_GLOBAL + (WMMA_M * blockDim.x / 32 - 1)) /
                (WMMA_M * blockDim.x / 32);
    gridDim.y = (N_GLOBAL + WMMA_N * blockDim.y - 1) / (WMMA_N * blockDim.y);

    printf("Computing... using simple_wmma_gemm kernel\n");
    simple_wmma_gemm<<<gridDim, blockDim>>>(A, B, C, D, M_GLOBAL, N_GLOBAL,
                                            K_GLOBAL, alpha, beta);
#if CPU_DEBUG
    checkCudaErrors(cudaMemcpy(result_hD, D,
                               sizeof(float) * M_GLOBAL * N_GLOBAL,
                               cudaMemcpyDeviceToHost));
#endif
  }

  checkCudaErrors(cudaEventRecord(stop));
  checkCudaErrors(cudaEventSynchronize(stop));

#if CPU_DEBUG
  printf("Verifying correctness of the computations...\n");

  memcpy(result_host, C_h, sizeof(float) * M_GLOBAL * N_GLOBAL);

  matMultiplyOnHost(A_h, B_h, result_host, alpha, beta, M_GLOBAL, K_GLOBAL,
                    K_GLOBAL, N_GLOBAL, M_GLOBAL, N_GLOBAL);

  for (int i = 0; i < N_GLOBAL * M_GLOBAL; i++) {
    if (fabs(result_hD[i] - result_host[i]) > 0.1f)
      printf("mismatch i=%d result_hD=%f result_host=%f\n", i, result_hD[i],
             result_host[i]);
  }
  free(result_hD);
  free(result_host);
#endif

  float milliseconds = 0;

  checkCudaErrors(cudaEventElapsedTime(&milliseconds, start, stop));

  printf("Time: %f ms\n", milliseconds);
  printf("TFLOPS: %.2f\n", static_cast<double>((static_cast<double>(M_GLOBAL) *
                                                N_GLOBAL * K_GLOBAL * 2) /
                                               (milliseconds / 1000.)) /
                               1e12);

  free(A_h);
  free(B_h);
  free(C_h);
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(A)));
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(B)));
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(C)));
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(D)));

  return 0;
}
