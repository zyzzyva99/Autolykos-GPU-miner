// autolykos.cu

#include "../include/prehash.h"
#include "../include/validation.h"
#include "../include/reduction.h"
#include "../include/compaction.h"
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <cuda.h>
#include <curand.h>

////////////////////////////////////////////////////////////////////////////////
//  Main cycle
////////////////////////////////////////////////////////////////////////////////
int main(int argc, char ** argv)
{
    //====================================================================//
    //  Host memory
    //====================================================================//
    uint32_t ind = 1;

    // hash context
    // 212 bytes
    blake2b_ctx ctx_h;

    // message stub
    // 8 * 32 bits = 32 bytes
    uint32_t mes_h[8] = {0, 0, 0, 0, 0, 0, 0, 0}; 

    // Autolykos puzzle results
    // L_LEN * 256 bits
    uint32_t * res_h = (uint32_t *)malloc(L_LEN * 8 * 4); 

    //====================================================================//
    // secret key
    //>>>genSKey();
    uint32_t sk_h[8] = {0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 1, 2}; 

    // public key
    //>>>genPKey();
    uint32_t pk_h[8] = {0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 3, 4}; 

    // one time secret key
    //>>>genSKey();
    uint32_t x_h[8] = {0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 5, 6}; 

    // one time public key
    //>>>genPKey();
    uint32_t w_h[8] = {0xA, 0xB, 0xC, 0xD, 0xE, 0xF, 7, 8}; 

    //====================================================================//
    //  Device memory
    //====================================================================//
    // nonces
    // H_LEN * L_LEN * NUM_BYTE_SIZE bytes // 128 MB
    uint32_t * non_d;
    CUDA_CALL(cudaMalloc((void **)&non_d, H_LEN * L_LEN * NUM_BYTE_SIZE));

    // data: pk || mes || w || x || sk || ctx
    // (5 * NUM_BYTE_SIZE + 212 + 4) bytes // ~0 MB
    uint32_t * data_d;
    CUDA_CALL(cudaMalloc((void **)&data_d, (NUM_BYTE_SIZE + B_DIM) * 4));

    // precalculated hashes
    // N_LEN * NUM_BYTE_SIZE bytes // 2 GB
    uint32_t * hash_d;
    CUDA_CALL(cudaMalloc((void **)&hash_d, (uint32_t)N_LEN * NUM_BYTE_SIZE));

    // indices of unfinalized hashes
    // H_LEN * N_LEN * 8 bytes // 512 MB
    uint32_t * indices_d;
    CUDA_CALL(cudaMalloc((void **)&indices_d, (uint32_t)H_LEN * N_LEN * 8));

    // potential solutions of puzzle
    // H_LEN * N_LEN * 4 bytes // 256 MB
    uint32_t * res_d;
    CUDA_CALL(cudaMalloc((void **)&res_d, (uint32_t)H_LEN * N_LEN * 4));

    //====================================================================//
    //  Random generator initialization
    //====================================================================//
    curandGenerator_t gen;
    CURAND_CALL(curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_MTGP32));
    
    time_t rawtime;
    // get current time (ms)
    time(&rawtime);

    // set seed
    CURAND_CALL(curandSetPseudoRandomGeneratorSeed(gen, (uint64_t)rawtime));

    //====================================================================//
    //  Memory: Host -> Device
    //====================================================================//
    CUDA_CALL(cudaMemcpy(
        (void *)data_d, (void *)pk_h, NUM_BYTE_SIZE, cudaMemcpyHostToDevice
    ));
    CUDA_CALL(cudaMemcpy(
        (void *)(data_d + (NUM_BYTE_SIZE >> 2)), (void *)mes_h,
        NUM_BYTE_SIZE, cudaMemcpyHostToDevice
    ));
    CUDA_CALL(cudaMemcpy(
        (void *)(data_d + 2 * (NUM_BYTE_SIZE >> 2)), (void *)w_h,
        NUM_BYTE_SIZE, cudaMemcpyHostToDevice
    ));
    CUDA_CALL(cudaMemcpy(
        (void *)(data_d + 3 * (NUM_BYTE_SIZE >> 2)), (void *)x_h,
        NUM_BYTE_SIZE, cudaMemcpyHostToDevice
    ));
    CUDA_CALL(cudaMemcpy(
        (void *)(data_d + 4 * (NUM_BYTE_SIZE >> 2)), (void *)sk_h,
        NUM_BYTE_SIZE, cudaMemcpyHostToDevice
    ));

    /// debug /// printf("%d\n", sizeof(ctx_h));
    /// debug /// printf("%d\n", sizeof(ctx_h.b));
    /// debug /// printf("%d\n", sizeof(ctx_h.h));
    /// debug /// printf("%d\n", sizeof(ctx_h.t));
    /// debug /// printf("%d\n", sizeof(ctx_h.c));

    //====================================================================//
    //  Autolykos puzzle cycle
    //====================================================================//
    struct timeval t1, t2;

    while (ind) //>>>(1)
    {
        gettimeofday(&t1, 0);

        // on obtaining solution
        /// debug /// if (ind == 1)
        if (ind)
        {
            //>>>genSKey();
            CUDA_CALL(cudaMemcpy(
                (void *)(data_d + 3 * (NUM_BYTE_SIZE >> 2)), (void *)x_h,
                NUM_BYTE_SIZE, cudaMemcpyHostToDevice
            ));
            //>>>genPKey();
            CUDA_CALL(cudaMemcpy(
                (void *)(data_d + 2 * (NUM_BYTE_SIZE >> 2)), (void *)w_h,
                NUM_BYTE_SIZE, cudaMemcpyHostToDevice
            ));

            prehash(data_d, hash_d, indices_d);
        }

        cudaThreadSynchronize();
        gettimeofday(&t2, 0);

        /// useful /// gettimeofday(&t1, 0);
        // generate nonces
        CURAND_CALL(curandGenerate(gen, non_d, L_LEN * H_LEN * NUM_BYTE_SIZE));

        // calculate unfinalized hash of message
        initMining(&ctx_h, mes_h, NUM_BYTE_SIZE);

        // context: host -> device
        CUDA_CALL(cudaMemcpy(
            (void *)(data_d + 5 * (NUM_BYTE_SIZE >> 2)), (void *)&ctx_h,
            sizeof(blake2b_ctx), cudaMemcpyHostToDevice
        ));

        // calculate hashes
        blockMining<<<G_DIM, B_DIM>>>(data_d, non_d, hash_d, res_d, indices_d);

        // try to find solution
        ind = findNonZero(indices_d, indices_d + H_LEN * N_LEN * 4);
        ind = 0;

        /// useful /// cudaThreadSynchronize();
        /// useful /// gettimeofday(&t2, 0);
    }

    double time
        = (1000000. * (t2.tv_sec - t1.tv_sec) + t2.tv_usec - t1.tv_usec)
        / 1000000.0;
    printf("Time to generate:  %.5f (s) \n", time);

    //====================================================================//
    //  Free device memory
    //====================================================================//
    CURAND_CALL(curandDestroyGenerator(gen));
    CUDA_CALL(cudaFree(non_d));
    CUDA_CALL(cudaFree(hash_d));
    CUDA_CALL(cudaFree(data_d));
    CUDA_CALL(cudaFree(indices_d));
    CUDA_CALL(cudaFree(res_d));

    return 0;
}

// autolykos.cu