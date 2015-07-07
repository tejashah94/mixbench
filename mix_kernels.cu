#include <stdio.h>
#include <math_constants.h>
#include "lcutil.h"
#include "timestamp.h"

#define COMP_ITERATIONS (8192)
#define UNROLL_ITERATIONS (32)
#define REGBLOCK_SIZE (4)

#define UNROLLED_MEMORY_ACCESSES (UNROLL_ITERATIONS/2)

template <class T, int blockdim, int memory_ratio, int griddim>
__global__ void benchmark_func(T seed, volatile T *g_data){
#ifdef BLOCK_STRIDED
	const int index_stride = blockdim;
	const int index_base = blockIdx.x*blockdim*UNROLLED_MEMORY_ACCESSES + threadIdx.x;
#else
	const int grid_size = blockdim * (griddim == 0 ? gridDim.x : griddim);
	const int globaltid = blockIdx.x * blockdim + threadIdx.x;
	const int index_stride = grid_size;
	const int index_base = globaltid;
#endif
	const int halfarraysize = gridDim.x*blockdim*UNROLLED_MEMORY_ACCESSES;
	const int offset_slips = 1+UNROLLED_MEMORY_ACCESSES-((memory_ratio+1)/2);
	const int array_index_bound = index_base+offset_slips*index_stride;
	volatile T *data = g_data;

	int array_index = index_base;
	T r0 = seed,
	  r1 = r0+(T)(31),
	  r2 = r0+(T)(37),
	  r3 = r0+(T)(41);

	for(int j=0; j<COMP_ITERATIONS; j+=UNROLL_ITERATIONS){
		#pragma unroll
		for(int i=0; i<UNROLL_ITERATIONS-memory_ratio; i++){
			// Each iteration maps to floating point 8 operations (4 multiplies + 4 additions)
			r0 = r0 * r0 + r1;//r0;
			r1 = r1 * r1 + r2;//r1;
			r2 = r2 * r2 + r3;//r2;
			r3 = r3 * r3 + r0;//r3;
		}
		bool do_write = true;
		int reg_idx = 0;
		#pragma unroll
		for(int i=UNROLL_ITERATIONS-memory_ratio; i<UNROLL_ITERATIONS; i++){
			// Each iteration maps to one memory operation
			T& r = reg_idx==0 ? r0 : (reg_idx==1 ? r1 : (reg_idx==2 ? r2 : r3));
			if( do_write )
				data[ array_index+halfarraysize ] = r;
			else {
				r = data[ array_index ];
				if( ++reg_idx>3 )
					reg_idx = 0;
				array_index += index_stride;
			}
			do_write = !do_write;
		}
		if( array_index >= array_index_bound )
			array_index = index_base;
	}
	if( (r0==(T)CUDART_INF) && (r1==(T)CUDART_INF) && (r2==(T)CUDART_INF) && (r3==(T)CUDART_INF) ){ // extremely unlikely to happen
		g_data[0] = r0+r1+r2+r3; 
	}
}

void initializeEvents(cudaEvent_t *start, cudaEvent_t *stop){
	CUDA_SAFE_CALL( cudaEventCreate(start) );
	CUDA_SAFE_CALL( cudaEventCreate(stop) );
	CUDA_SAFE_CALL( cudaEventRecord(*start, 0) );
}

float finalizeEvents(cudaEvent_t start, cudaEvent_t stop){
	CUDA_SAFE_CALL( cudaGetLastError() );
	CUDA_SAFE_CALL( cudaEventRecord(stop, 0) );
	CUDA_SAFE_CALL( cudaEventSynchronize(stop) );
	float kernel_time;
	CUDA_SAFE_CALL( cudaEventElapsedTime(&kernel_time, start, stop) );
	CUDA_SAFE_CALL( cudaEventDestroy(start) );
	CUDA_SAFE_CALL( cudaEventDestroy(stop) );
	return kernel_time;
}

void runbench_warmup(double *cd, long size){
	const long reduced_grid_size = size/(UNROLLED_MEMORY_ACCESSES)/32;
	const int BLOCK_SIZE = 256;
	const int TOTAL_REDUCED_BLOCKS = reduced_grid_size/BLOCK_SIZE;
	const int shared_size = 0;

	dim3 dimBlock(BLOCK_SIZE, 1, 1);
	dim3 dimReducedGrid(TOTAL_REDUCED_BLOCKS, 1, 1);

	benchmark_func< short, BLOCK_SIZE, 0, 0 ><<< dimReducedGrid, dimBlock, shared_size >>>((short)1, (short*)cd);
	CUDA_SAFE_CALL( cudaGetLastError() );
	CUDA_SAFE_CALL( cudaThreadSynchronize() );
}

template<int memory_ratio>
void runbench(double *cd, long size){
	if( memory_ratio>UNROLL_ITERATIONS ){
		fprintf(stderr, "ERROR: memory_ratio exceeds UNROLL_ITERATIONS\n");
		exit(1);
	}
		
	const long compute_grid_size = size/(UNROLLED_MEMORY_ACCESSES)/2;
	const int BLOCK_SIZE = 256;
	const int TOTAL_BLOCKS = compute_grid_size/BLOCK_SIZE;
	const long long computations = 2*(long long)(COMP_ITERATIONS)*REGBLOCK_SIZE*compute_grid_size;
	const long long memoryoperations = (long long)(COMP_ITERATIONS)*compute_grid_size;

	dim3 dimBlock(BLOCK_SIZE, 1, 1);
    dim3 dimGrid(TOTAL_BLOCKS, 1, 1);
	cudaEvent_t start, stop;
	const int shared_count = 0;

	initializeEvents(&start, &stop);
	benchmark_func< float, BLOCK_SIZE, memory_ratio, 0 ><<< dimGrid, dimBlock, shared_count*sizeof(float) >>>(1.0f, (float*)cd);
	float kernel_time_mad_sp = finalizeEvents(start, stop);

	initializeEvents(&start, &stop);
	benchmark_func< double, BLOCK_SIZE, memory_ratio, 0 ><<< dimGrid, dimBlock, shared_count*sizeof(double) >>>(1.0, cd);
	float kernel_time_mad_dp = finalizeEvents(start, stop);

	initializeEvents(&start, &stop);
	benchmark_func< int, BLOCK_SIZE, memory_ratio, 0 ><<< dimGrid, dimBlock, shared_count*sizeof(int) >>>(1, (int*)cd);
	float kernel_time_mad_int = finalizeEvents(start, stop);

	const double memaccesses_ratio = (double)(memory_ratio)/UNROLL_ITERATIONS;
	const double computations_ratio = 1.0-memaccesses_ratio;

	printf("      %2d/%2d,     %8.2f,%8.2f,%7.2f,%8.2f,%8.2f,%7.2f,%8.2f,%8.2f,%7.2f\n", 
		UNROLL_ITERATIONS-memory_ratio, memory_ratio,
		kernel_time_mad_sp,
		(computations_ratio*(double)computations)/kernel_time_mad_sp*1000./(double)(1000*1000*1000),
		(memaccesses_ratio*(double)memoryoperations*sizeof(float))/kernel_time_mad_sp*1000./(1000.*1000.*1000.),
		kernel_time_mad_dp,
		(computations_ratio*(double)computations)/kernel_time_mad_dp*1000./(double)(1000*1000*1000),
		(memaccesses_ratio*(double)memoryoperations*sizeof(double))/kernel_time_mad_dp*1000./(1000.*1000.*1000.),
		kernel_time_mad_int,
		(computations_ratio*(double)computations)/kernel_time_mad_int*1000./(double)(1000*1000*1000),
		(memaccesses_ratio*(double)memoryoperations*sizeof(int))/kernel_time_mad_int*1000./(1000.*1000.*1000.) );
}

extern "C" void mixbenchGPU(double *c, long size){
#ifdef BLOCK_STRIDED
	const char *benchtype = "compute with global memory (block strided)";
#else
	const char *benchtype = "compute with global memory (grid strided)";
#endif
	printf("Trade-off type:%s\n", benchtype);
	double *cd;

	CUDA_SAFE_CALL( cudaMalloc((void**)&cd, size*sizeof(double)) );

	// Copy data to device memory
	CUDA_SAFE_CALL( cudaMemset(cd, 0, size*sizeof(double)) );  // initialize to zeros

	// Synchronize in order to wait for memory operations to finish
	CUDA_SAFE_CALL( cudaThreadSynchronize() );

	printf("----------------------------------------- EXCEL data -----------------------------------------\n");
	printf("Operations ratio,  Single Precision ops,,,   Double precision ops,,,     Integer operations,, \n");
	printf("  compute/memory,    Time,  GFLOPS, GB/sec,    Time,  GFLOPS, GB/sec,    Time,   GIOPS, GB/sec\n");

	runbench_warmup(cd, size);

	runbench<32>(cd, size);
	runbench<31>(cd, size);
	runbench<30>(cd, size);
	runbench<29>(cd, size);
	runbench<28>(cd, size);
	runbench<27>(cd, size);
	runbench<26>(cd, size);
	runbench<25>(cd, size);
	runbench<24>(cd, size);
	runbench<23>(cd, size);
	runbench<22>(cd, size);
	runbench<21>(cd, size);
	runbench<20>(cd, size);
	runbench<19>(cd, size);
	runbench<18>(cd, size);
	runbench<17>(cd, size);
	runbench<16>(cd, size);
	runbench<15>(cd, size);
	runbench<14>(cd, size);
	runbench<13>(cd, size);
	runbench<12>(cd, size);
	runbench<11>(cd, size);
	runbench<10>(cd, size);
	runbench<9>(cd, size);
	runbench<8>(cd, size);
	runbench<7>(cd, size);
	runbench<6>(cd, size);
	runbench<5>(cd, size);
	runbench<4>(cd, size);
	runbench<3>(cd, size);
	runbench<2>(cd, size);
	runbench<1>(cd, size);
	runbench<0>(cd, size);

	printf("----------------------------------------------------------------------------------------------\n");

	// Copy results back to host memory
	CUDA_SAFE_CALL( cudaMemcpy(c, cd, size*sizeof(double), cudaMemcpyDeviceToHost) );

	CUDA_SAFE_CALL( cudaFree(cd) );

	CUDA_SAFE_CALL( cudaDeviceReset() );
}
