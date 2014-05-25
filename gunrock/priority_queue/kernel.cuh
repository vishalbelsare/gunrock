// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * kernel.cuh
 *
 * @brief Priority Queue Kernel
 */

#pragma once

#include <gunrock/util/cta_work_distribution.cuh>
#include <gunrock/util/cta_work_progress.cuh>
#include <gunrock/util/kernel_runtime_stats.cuh>

#include <gunrock/priority_queue/near_far.cuh>

#include <moderngpu.cuh>

namespace gunrock {
namespace priority_queue {

/**
 * Arch dispatch
 */

/**
 * Not valid for this arch (default)
 */
template<
    typename    KernelPolicy,
    typename    ProblemData,
    typename    PriorityQueue,
    typename    Functor,
    bool        VALID = (__GR_CUDA_ARCH__ >= KernelPolicy::CUDA_ARCH)>
struct Dispatch
{
    typedef typename KernelPolicy::VertexId     VertexId;
    typedef typename KernelPolicy::SizeT        SizeT;
    typedef typename KernelPolicy::Value        Value;
    typedef typename ProblemData::DataSlice     DataSlice;

    static __device__ __forceinline__ void MarkNF(
            VertexId     *&vertex_in,
            DataSlice       *&problem,
            SizeT &input_queue_length,
            Value &lower_priority_score_limit,
            Value &upper_priority_score_limit,
            Value &delta)
    {
    }

    static __device__ __forceinline__ void Compact(
            VertexId     *&vertex_in,
            PriorityQueue *&pq,
            SizeT &input_queue_length,
            VertexId     *&vertex_out,
            SizeT &v_out_offset)
    {
    }
};

template<
    typename KernelPolicy,
    typename ProblemData,
    typename PriorityQueue,
    typename Functor>
struct Dispatch<KernelPolicy, ProblemData, PriorityQueue, Functor, true>
{
    typedef typename KernelPolicy::VertexId     VertexId;
    typedef typename KernelPolicy::SizeT        SizeT;
    typedef typename KernelPolicy::Value        Value;
    typedef typename ProblemData::DataSlice     DataSlice;

    static __device__ __forceinline__ void MarkNF(
                                            VertexId     *&vertex_in,
                                            DataSlice       *&problem,
                                            SizeT &input_queue_length,
                                            Value &lower_priority_score_limit,
                                            Value &upper_priority_score_limit,
                                            Value &delta)
    {
        int tid = threadIdx.x;
        int bid = blockIdx.x;
        int my_id = tid + bid*blockDim.x;

        if (my_id >= input_queue_length)
            return;

        unsigned int bucket_max = UINT_MAX/delta;
        unsigned int my_vert = vertex_in[my_id];
        unsigned int bucket_id = Functor::ComputePriorityScore(my_vert, problem);
        pq->valid_near[my_id] = (bucket_id < upper_priority_score_limit && bucket_id >= lower_priority_score_limit);
        pq->valid_far[my_id] = (bucket_id >= upper_priority_score_limit && bucket_id < bucket_max);

    }

    static __device__ __forceinline__ void Compact(
                                            VertexId     *&vertex_in,
                                            PriorityQueue *&pq,
                                            SizeT &input_queue_length,
                                            VertexId     *&vertex_out,
                                            SizeT &v_out_offset)
    {
        int tid = threadIdx.x;
        int bid = blockIdx.x;
        int my_id = bid*blockDim.x + tid;
        if (my_id >= input_queue_length)
            return;

        unsigned int my_vert = vertex_in[my_id];
        unsigned int my_valid = pq->valid_near[my_id];

        if (my_valid == pq->valid_near[my_id+1]-1)
            vertex_out[my_valid+v_out_offset] = my_vert;

        my_valid = pq->valid_far[my_id];
        if (my_valid == pq->valid_far[my_id+1]-1)
            pq->queue[my_valid+pq->queue_length] = my_vert;
        
    }
};

template<typename KernelPolicy, typename ProblemData, typename PriorityQueue, typename Functor>
__launch_bounds__ (KernelPolicy::THREADS, KernelPolicy::BLOCKS)
    __global__
void MarkNF(
        typename KernelPolicy::VertexId     *vertex_in,
        typename ProblemData::DataSlice     *problem,
        typename KernelPolicy::SizeT        input_queue_length,
        typename KernelPolicy::Value        lower_priority_score_limit,
        typename KernelPolicy::Value        upper_priority_score_limit,
        typename KernelPolicy::Value        delta)
{
    Dispatch<KernelPolicy, ProblemData, PriorityQueue, Functor>::MarkNF(
            vertex_in,
            problem,
            input_queue_length,
            lower_priority_score_limit,
            upper_priority_score_limit,
            delta);
}

template<typename KernelPolicy, typename ProblemData, typename PriorityQueue, typename Functor>
__launch_bounds__ (KernelPolicy::THREADS, KernelPolicy::BLOCKS)
    __global__
void Compact(
        typename KernelPolicy::VertexId     *vertex_in,
        typename PriorityQueue              *pq,
        typename KernelPolicy::SizeT        input_queue_length,
        typename KernelPolicy::VertexId     *vertex_out,
        typename KernelPolicy::SizeT        v_out_offset)
{
    Dispatch<KernelPolicy, ProblemData, Functor>::Compact(
        vertex_in,
        pq,
        input_queue_length,
        vertex_out,
        v_out_offset);
}

template <typename KernelPolicy, typename ProblemData, typename PriorityQueue, typename Functor>
    void Bisect(
        typename KernelPolicy::VertexId     *vertex_in,
        typename PriorityQueue              *pq,
        typename KernelPolicy::SizeT        input_queue_length,
        typename ProblemData::DataSlice     *problem,
        typename KernelPolicy::VertexId     *vertex_out,
        typename KernelPolicy::SizeT        output_queue_length,
        typename KernelPolicy::Value        lower_limit,
        typename KernelPolicy::Value        upper_limit,
        typename KernelPolicy::Value        delta,
        CudaContext                         &context)
{
    int block_num = (input_queue_length + KernelPolicy::THREADS - 1) / KernelPolicy::THREADS;
    int close_size[1] = {0};
    int far_size[1] = {0};
    if(input_queue_length > 0)
    {
        // MarkNF
        MarkNF(vertex_in, problem, input_queue_length, lower_limit, upper_limit, delta);

        // Scan(near)
        // Scan(far)
        Scan<mgpu::MgpuScanTypeExc>(pq->valid_near, input_queue_length+1, context);
        Scan<mgpu::MgpuScanTypeExc>(pq->valid_far, input_queue_length+1, context);       
        // Compact
        Compact(vertex_in, pq, input_queue_length, vertex_out, 0);
        // get output_near_length
        // get output_far_length
        cudaMemcpy(&close_size[0], pq->valid_near+input_queue_length, sizeof(VertexId),
		    cudaMemcpyDeviceToHost);
		cudaMemcpy(&far_size[0], pq->valid_far+input_queue_length, sizeof(VertexId),
		    cudaMemcpyDeviceToHost);

    }
    // Update near/far length
    output_queue_length = close_size;
    pq->queue_length += far_size;
}

} //priority_queue
} //gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
