// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * circular_queue.cuh
 *
 * @brief asynchronous circular queue
 */

#pragma once

#include <list>
#include <mutex>
#include <chrono>
#include <thread>
#include <string>
#include <gunrock/util/basic_utils.h>
#include <gunrock/util/error_utils.cuh>
#include <gunrock/util/array_utils.cuh>

namespace gunrock {
namespace util {

template <
    typename SizeT,
    typename VertexId,
    typename Value   = VertexId,
    bool AUTO_RESIZE = true>
struct CircularQueue
{
public:

    class CqEvent{
    public:
        int   status;
        SizeT offset, length;
        cudaEvent_t event;

        CqEvent(
            SizeT offset_,
            SizeT length_) :
            status(0      ),
            offset(offset_),
            length(length_)
        {
        }
    }; // end of CqEvent

private:
    std::string  name;      // name of the queue
    int          gpu_idx ;  // gpu index
    SizeT        capacity;  // capacity of the queue
    SizeT        size_occu; // occuplied size
    SizeT        size_soli; // size of the fixed part
    unsigned int allocated; // where the data is allocated, HOST or DEVICE
    Array1D<SizeT, VertexId>  array; // the main data
    Array1D<SizeT, VertexId>  *vertex_associates; // VertexId type associate values
    Array1D<SizeT, Value   >  *value__associates; // Value type associate values
    SizeT        num_vertex_associates;
    SizeT        num_value__associates;
    SizeT        head_a, head_b, tail_a, tail_b; // head and tail offsets
    std::list<CqEvent > events[2]; // 0 for in events, 1 for out events
    std::list<cudaEvent_t> empty_gpu_events;
    cudaEvent_t *gpu_events;
    SizeT        num_events;
    std::mutex   queue_mutex;
    int          wait_resize;
    //SizeT        temp_capacity;
    Array1D<SizeT, VertexId> temp_array;
    Array1D<SizeT, VertexId> temp_vertex_associates;
    Array1D<SizeT, Value   > temp_value__associates;

public:
    CircularQueue() :
        name      (""  ),
        gpu_idx   (0   ),
        capacity  (0   ),
        size_occu (0   ),
        size_soli (0   ),
        allocated (NONE),
        vertex_associates(NULL),
        value__associates(NULL),
        num_vertex_associates(0),
        num_value__associates(0),
        head_a    (0   ),
        head_b    (0   ),
        tail_a    (0   ),
        tail_b    (0   ),
        gpu_events(NULL),
        num_events(0   ),
        wait_resize(0  )
        //temp_capacity(0)
    {
        SetName("cq");
    }

    ~CircularQueue()
    {
        Release();
    }

    void SetName(std::string name)
    {
        this->name = name;
        array                 .SetName(name+"_array"      );
        //vertex_associates     .SetName(name+"_vertex"     );
        //value__associates     .SetName(name+"_value"      );
        temp_array            .SetName(name+"_temp_array" );
        temp_vertex_associates.SetName(name+"_temp_vertex");
        temp_value__associates.SetName(name+"_temp_value" );
    }

    cudaError_t Init(
        SizeT        capacity, 
        unsigned int target   = HOST,
        SizeT        num_events = 10,
        SizeT        num_vertex_associates = 0,
        SizeT        num_value__associates = 0,
        SizeT        temp_capacity = 0)
    {
        cudaError_t retval = cudaSuccess;

        this->capacity = capacity;
        if (retval = array.Allocate(capacity, target)) return retval;
        if (num_vertex_associates != 0)
        {
            vertex_associates = new Array1D<SizeT, VertexId>[num_vertex_associates];
            for (SizeT i=0; i<num_vertex_associates; i++)
            {
                vertex_associates[i].SetName(name + "_vertex[]");
                if (retval = vertex_associates[i].Allocate(capacity, target))
                return retval;
            }
        }
        if (num_value__associates != 0)
        {
            value__associates = new Array1D<SizeT, Value   >[num_value__associates];
            for (SizeT i=0; i<num_value__associates; i++)
            {
                value__associates[i].SetName(name + "_value[]");
                if (retval = value__associates[i].Allocate(capacity, target))
                return retval;
            }
        }
        this -> num_vertex_associates = num_vertex_associates;
        this -> num_value__associates = num_value__associates;
        allocated = target;
        head_a    = 0; head_b = 0;
        tail_a    = 0; tail_b = 0;
        size_occu = 0; size_soli = 0;
        wait_resize = 0;

        if (temp_capacity != 0)
        {
            if (retval = temp_array.Allocate(temp_capacity, target)) return retval;
            if (retval = temp_vertex_associates.Allocate(temp_capacity * num_vertex_associates, target))
                return retval;
            if (retval = temp_value__associates.Allocate(temp_capacity * num_value__associates, target))
                return retval;
            //this->temp_capacity = temp_capacity;
        }
       
        if (target == DEVICE)
        { 
            if (retval = GRError(cudaGetDevice(&gpu_idx), 
                "cudaGetDevice failed", __FILE__, __LINE__)) return retval;
            gpu_events = new cudaEvent_t[num_events];
            this -> num_events = num_events;
            for (SizeT i=0; i<num_events; i++)
            {
                if (retval = GRError(cudaEventCreateWithFlags(gpu_events + i, cudaEventDisableTiming), 
                    "cudaEventCreateWithFlags failed", __FILE__, __LINE__)) 
                    return retval;
                empty_gpu_events.push_back(gpu_events[i]);
            }
        }

        events[0].clear();
        events[1].clear();

        return retval;
    }

    cudaError_t Release()
    {
        cudaError_t retval = cudaSuccess;

        if (allocated == DEVICE)
        {
            for (SizeT i=0; i<num_events; i++)
            {
                if (retval = cudaEventDestroy(gpu_events[i])) return retval;
            }
            delete[] gpu_events; gpu_events = NULL;
            empty_gpu_events.clear();
        }
        events[0].clear();
        events[1].clear();

        if (vertex_associates != NULL)
        {
            for (SizeT i=0; i<num_vertex_associates; i++)
                if (retval = vertex_associates[i].Release()) return retval;
            delete[] vertex_associates; vertex_associates = NULL;
        }
        if (value__associates != NULL)
        {
            for (SizeT i=0; i<num_value__associates; i++)
                if (retval = value__associates[i].Release()) return retval;
            delete[] value__associates; value__associates = NULL;
        }

        if (retval = array.Release()                 ) return retval;
        //if (retval = vertex_associates.Release()     ) return retval;
        //if (retval = value__associates.Release()     ) return retval;
        if (retval = temp_array.Release()            ) return retval;
        if (retval = temp_vertex_associates.Release()) return retval;
        if (retval = temp_value__associates.Release()) return retval;

        return retval;
    }

    void GetSize(SizeT &size_occu, SizeT &size_soli)
    {
        size_soli = this->size_soli;
        size_occu = this->size_occu;
    }

    SizeT GetCapacity()
    {
        return capacity;
    }

    cudaError_t Combined_Return(
        cudaError_t retval = cudaSuccess, 
        bool        in_critical = true,
        bool        set_gpu     = false,
        int         org_gpu     = 0)
    {
        if (!in_critical) queue_mutex.unlock();
        if (retval == cudaSuccess)
            retval = GRError(cudaSetDevice(org_gpu),
                "cudaSetDevice failed", __FILE__, __LINE__);
        return retval;
    }

    void ShowDebugInfo(
        std::string function_name,
        int         direction,
        SizeT       start,
        SizeT       end,
        SizeT       dsize,
        Value*      value = NULL)
    {
        printf("%s\t %s\t %d\t %d\t ~ %d\t %d\t %d\t %d\t %d\t %d\t %d\t %d\n",
            function_name.c_str(), direction == 0? "->" : "<-",
            value == NULL ? -1 : value[0], start, end, dsize, size_occu, size_soli,
            head_a, head_b, tail_a, tail_b);
        //fflush(stdout);
    }

    cudaError_t Push(
        SizeT         length, 
        VertexId     *array, 
        cudaStream_t  stream = 0,
        SizeT         num_vertex_associates = 0, 
        SizeT         num_value__associates = 0,
        VertexId    **vertex_associates = NULL,
        Value       **value__associates = NULL)
    {
        cudaError_t retval = cudaSuccess;
        SizeT offsets[2] = {0, 0};
        SizeT lengths[2] = {0, 0};
        SizeT sum        = 0;
        if (retval = AddSize(length, offsets, lengths)) return retval;

        for (int i=0; i<2; i++)
        {
            if (lengths[i] == 0) continue;
            ShowDebugInfo("Push", 0, offsets[i], offsets[i] + lengths[i], lengths[i]);
            if (retval = this->array.Move_In(
                allocated, allocated, array, 
                lengths[i], sum, offsets[i], stream)) 
                return retval;
            for (SizeT j=0; j<num_vertex_associates; j++)
            {
                if (retval = this->vertex_associates[j].Move_In(
                    allocated, allocated, vertex_associates[j], 
                    lengths[i], sum, offsets[i], stream))
                    return retval;
            }
            for (SizeT j=0; j<num_value__associates; j++)
            {
                if (retval = this->value__associates[j].Move_In(
                    allocated, allocated, value__associates[j], 
                    lengths[i], sum, offsets[i], stream))
                    return retval;
            }

            // in_event finish
            if (allocated == HOST) EventFinish(0, offsets[i], lengths[i]);
            else if (allocated == DEVICE)
                EventSet(0, offsets[i], lengths[i], stream);
            sum += lengths[i];
        } 
        return retval;
    }

    cudaError_t Push_Addr(
        SizeT         length, 
        VertexId    *&array, 
        SizeT        &offset,
        SizeT         num_vertex_associates = 0, 
        SizeT         num_value__associates = 0,
        VertexId    **vertex_associates = NULL,
        Value       **value__associates = NULL,
        bool          set_gpu = false)
    {
        cudaError_t retval = cudaSuccess;
        SizeT offsets[2] = {0,0};
        SizeT lengths[2] = {0,0};
        SizeT sum        = 0;
        if (retval = AddSize(length, offsets, lengths, set_gpu)) return retval;
        offset = offsets[0];

        if (lengths[1] == 0)
        { // single chunk
            array = this->array.GetPointer(allocated) + offsets[0];
            for (SizeT j=0; j<num_vertex_associates; j++)
                vertex_associates[j] = this->vertex_associates[j].GetPointer(allocated) + offsets[0];
            for (SizeT j=0; j<num_value__associates; j++)
                value__associates[j] = this->value__associates[j].GetPointer(allocated) + offsets[0];
        } else { // splict at the end
            if (length > temp_array.GetSize() ||
                length * num_vertex_associates > temp_vertex_associates.GetSize() || 
                length * num_value__associates > temp_value__associates.GetSize())
            {
                if (!AUTO_RESIZE)
                {
                    retval = util::GRError(cudaErrorLaunchOutOfResources, 
                        (name + " remp_array oversize ").c_str(), __FILE__, __LINE__);
                    return retval;
                }
                int org_gpu = 0;
                if (set_gpu && allocated == DEVICE)
                {
                    if (retval = GRError(cudaGetDevice(&org_gpu),
                        "cudaGetDevice failed", __FILE__, __LINE__))
                        return retval;
                    if (retval = GRError(cudaSetDevice(gpu_idx),
                        "cudaSetDevice failed", __FILE__, __LINE__))
                        return retval;
                }
                if (retval = temp_array.EnsureSize(length, false, 0, allocated))
                    return retval;
                if (retval = temp_vertex_associates.EnsureSize(length * num_vertex_associates, false, 0, allocated))
                    return retval;
                if (retval = temp_value__associates.EnsuerSize(length * num_value__associates, false, 0, allocated))
                    return retval;
                if (set_gpu && allocated == DEVICE)
                {
                    if (retval = GRError(cudaSetDevice(org_gpu),
                        "cudaSetDevice failed", __FILE__, __LINE__))
                        return retval;
                }
            }
            array = temp_array.GetPointer(allocated);
            for (SizeT j=0; j<num_vertex_associates; j++)
                vertex_associates[j] = temp_vertex_associates.GetPointer(allocated) + j*length;
            for (SizeT j=0; j<num_value__associates; j++)
                value__associates[j] = temp_value__associates.GetPointer(allocated) + j*length;
        }
        return retval;
    }
 
    cudaError_t Pop(
        SizeT         min_length, 
        SizeT         max_length, 
        VertexId     *array, 
        SizeT        &length, 
        cudaStream_t  stream = 0,
        SizeT         num_vertex_associates = 0,
        SizeT         num_value__associates = 0,
        VertexId    **vertex_associates = NULL,
        Value       **value__associates = NULL)
    {
        cudaError_t retval = cudaSuccess;
        SizeT offsets[2] = {0, 0};
        SizeT lengths[2] = {0, 0};
        SizeT sum        = 0;
        
        if (retval = ReduceSize(min_length, max_length, offsets, lengths)) return retval;

        for (int i=0; i<2; i++)
        {
            if (lengths[i] == 0) continue;
            ShowDebugInfo("Pop", 1, offsets[i], offsets[i] + lengths[i], lengths[i]);
            if (retval = this->array.Move_Out(
                allocated, allocated, array, 
                lengths[i], sum, offsets[i], stream)) 
                return retval;
            for (SizeT j=0; j<num_vertex_associates; j++)
            {
                if (retval = this->vertex_associates[j].Move_Out(
                    allocated, allocated, vertex_associates[j], 
                    lengths[i], sum, offsets[i], stream))
                    return retval;
            }
            for (SizeT j=0; j<num_value__associates; j++)
            {
                if (retval = this->value__associates[j].Move_Out(
                    allocated, allocated, value__associates[j], 
                    lengths[i], sum, offsets[i], stream))
                    return retval;
            }
            if (allocated == HOST) EventFinish(1, offsets[i], lengths[i]);
            else if (allocated == DEVICE)
                EventSet(1, offsets[i], lengths[i], stream);
            sum += lengths[i];
        }
        length = sum;

        return retval; 
    }

    cudaError_t Pop_Addr(
        SizeT         min_length, 
        SizeT         max_length, 
        VertexId    *&array, 
        SizeT        &length, 
        SizeT        &offset,
        cudaStream_t  stream = 0,
        SizeT         num_vertex_associates = 0,
        SizeT         num_value__associates = 0,
        VertexId    **vertex_associates = NULL,
        Value       **value__associates = NULL,
        bool          set_gpu = false)
    {
        cudaError_t retval = cudaSuccess;
        SizeT offsets[2] = {0, 0};
        SizeT lengths[2] = {0, 0};
        SizeT sum        = 0;

        if (retval = ReduceSize(min_length, max_length, offsets, lengths, set_gpu)) return retval;
        offset = offsets[0];
        length = lengths[0] + lengths[1];

        if (offsets[1] == 0)
        { // single chunk
            array = this->array.GetPointer(allocated) + offset;
            for (SizeT j=0; j<num_vertex_associates; j++)
                vertex_associates[j] = this->vertex_associates[j].GetPointer(allocated) + offset;
            for (SizeT j=0; j<num_value__associates; j++)
                value__associates[j] = this->value__associates[j].GetPointer(allocated) + offset; 
        } else {
            int org_gpu;
            if (set_gpu && allocated == DEVICE)
            {
                if (retval = GRError(cudaGetDevice(&org_gpu),
                    "cudaGetDevice failed", __FILE__, __LINE__))
                    return retval;
                if (retval = GRError(cudaSetDevice(gpu_idx),
                    "cudaSetDevice failed", __FILE__, __LINE__))
                    return retval;
            }

            if (length > temp_array.GetSize() ||
                length * num_vertex_associates > temp_vertex_associates.GetSize() ||
                length * num_value__associates > temp_value__associates.GetSize())
            {
                if (!AUTO_RESIZE)
                {
                    retval = util::GRError(cudaErrorLaunchOutOfResources, 
                        (name + " temp_array oversize ").c_str(), __FILE__, __LINE__);
                    return retval;
                }
                if (temp_array.EnsureSize(length, false, 0, allocated))
                    return retval;
                if (temp_vertex_associates.EnsureSize(length * num_vertex_associates, false, 0, allocated))
                    return retval;
                if (temp_value__associates.EnsureSize(length * num_value__associates, false, 0, allocated))
                    return retval;
            }
            
            for (int i=0; i<2; i++)
            {
                if (lengths[i] == 0) continue;
                if (retval = this->array.Move_Out(
                    allocated, allocated, temp_array.GetPointer(allocated), 
                    lengths[i], sum, offsets[i], stream)) return retval;
                for (SizeT j=0; j<num_vertex_associates; j++)
                {
                    if (retval = this->vertex_associates[j].Move_Out(
                        allocated, allocated, temp_vertex_associates.GetPointer(allocated), 
                        lengths[i], j*length + sum, offsets[i], stream)) return retval;
                }
                for (SizeT j=0; j<num_value__associates; j++)
                {
                    if (retval = this->value__associates[j].Move_Out(
                        allocated, allocated, temp_value__associates.GetPointer(allocated),
                        lengths[i], j*length + sum, offsets[i], stream)) return retval;
                }
                sum += lengths[i];
            }
            if (set_gpu && allocated == DEVICE)
            {
                if (retval = GRError(cudaSetDevice(org_gpu),
                    "cudaSetDevice failed", __FILE__, __LINE__))
                    return retval;
            }
            array = temp_array.GetPointer(allocated);
            for (SizeT j=0; j<num_vertex_associates; j++)
                vertex_associates[j] = temp_vertex_associates.GetPointer(allocated) + j*length;
            for (SizeT j=0; j<num_value__associates; j++)
                value__associates[j] = temp_value__associates.GetPointer(allocated) + j*length;
           
        }
        return retval; 
    }
 
    cudaError_t AddSize(
        SizeT  length, 
        SizeT *offsets, 
        SizeT *lengths, 
        bool   in_critical = false,
        bool   single_chunk = false)
    {
        cudaError_t retval = cudaSuccess;

        // in critical sectioin
        while (wait_resize != 0)
            std::this_thread::sleep_for(std::chrono::microseconds(10));
        if (!in_critical) queue_mutex.lock();
        bool past_wait = false;
        while (!past_wait)
        {
            if (wait_resize == 0) {past_wait = true; break;}
            else {
                queue_mutex.unlock();
                std::this_thread::sleep_for(std::chrono::microseconds(10));
                queue_mutex.lock();
            }
        }
       
        if (allocated == DEVICE)
        {
            if (retval = EventCheck(1, true)) 
                return Combined_Return(retval, in_critical);
        }
         
        if (length + size_occu > capacity) 
        { // queue full
            if (AUTO_RESIZE)
            {
                if (retval = EnsureCapacity(length + size_occu, true)) 
                    return Combined_Return(retval, in_critical);
            } else {
                if (length > capacity)
                { // too large for the queue
                    retval = util::GRError(cudaErrorLaunchOutOfResources, 
                        (name + " oversize ").c_str(), __FILE__, __LINE__);
                    return Combined_Return(retval, in_critical);
                } else {
                    queue_mutex.unlock();
                    bool got_space = false;
                    while (!got_space)
                    {
                        if (length + size_occu < capacity)
                        {
                            queue_mutex.lock();
                            if (length + size_occu < capacity)
                            {
                                got_space = true;
                            } else {
                                queue_mutex.unlock();
                            }
                        }
                        if (!got_space) {
                            std::this_thread::sleep_for(std::chrono::microseconds(10));
                        }
                    }
                }
            }
        }

        if (head_a + length > capacity)
        { // splict
            offsets[0] = head_a;
            lengths[0] = capacity - head_a;
            offsets[1] = 0;
            lengths[1] = length - lengths[0];
            if (single_chunk)
            { // only single event
                EventStart(0, offsets[0], length    , true);
            } else { // two events
                EventStart(0, offsets[0], lengths[0], true);
                EventStart(0, offsets[1], lengths[1], true);
            }
            head_a     = lengths[1];
        } else { // no splict
            offsets[0] = head_a;
            lengths[0] = length;
            EventStart(0, offsets[0], lengths[0], true);
            offsets[1] = 0;
            lengths[1] = 0;
            head_a += length;
            if (head_a >= capacity) head_a -= capacity;
        }
        size_occu += length;

        ShowDebugInfo("AddSize", 0, offsets[0], head_a, length);
        return Combined_Return(retval, in_critical);
    }

    cudaError_t ReduceSize(
        SizeT  min_length, 
        SizeT  max_length, 
        SizeT *offsets, 
        SizeT *lengths, 
        bool   in_critical = false,
        bool   single_chunk = false)
    {
        cudaError_t retval = cudaSuccess;
        SizeT length = 0;
        // in critial section
        while (wait_resize != 0)
            std::this_thread::sleep_for(std::chrono::microseconds(10));
        if (!in_critical) queue_mutex.lock();

        if (allocated == DEVICE)
        {
            if (retval = EventCheck(0, true))
                return Combined_Return(retval, in_critical);
        }
        
        if (size_soli < min_length)
        { // too small
            queue_mutex.unlock();
            bool got_content = false;
            while (!got_content)
            {
                if (size_soli >= min_length)
                {
                    queue_mutex.lock();
                    if (size_soli >= min_length)
                    {
                        got_content = true;
                    } else {
                        queue_mutex.unlock();
                    }
                }
                if (!got_content) {
                    std::this_thread::sleep_for(std::chrono::microseconds(10));
                }
            }
        }

        length = size_soli < max_length ? size_soli : max_length;
        if (tail_a + length > capacity)
        { // splict
            offsets[0] = tail_a;
            lengths[0] = capacity - tail_a;
            offsets[1] = 0;
            lengths[1] = length - lengths[0];
            if (single_chunk)
            { // single event
                EventStart(1, offsets[0], length    , true);
            } else { // two events
                EventStart(1, offsets[0], lengths[0], true);
                EventStart(1, offsets[1], lengths[1], true);
            }
            tail_a     = lengths[1];
        } else {
            offsets[0] = tail_a;
            lengths[0] = length;
            EventStart(1, offsets[0], lengths[0], true);
            offsets[1] = 0;
            lengths[1] = 0;
            tail_a += length;
            if (tail_a == capacity) tail_a = 0;
        }
        size_soli -= length;

        ShowDebugInfo("RedSize", 1, offsets[0], tail_a, length);
        return Combined_Return(retval, in_critical);
    }

    cudaError_t EnsureCapacity(
        SizeT capacity_, 
        bool  in_critical = false,
        bool  set_gpu     = false)
    {
        cudaError_t retval = cudaSuccess;
        int org_gpu;
        
        if (set_gpu && allocated = DEVICE)
        { // set to the correct device
            if (retval = GRError(cudaGetDevice(&org_gpu),
                "cudaGetDevice failed", __FILE__, __LINE__))
                return retval;
            if (retval = GRError(cudaSetDevice(gpu_idx),
                "cudaSetDevice failed", __FILE__, __LINE__))
                return retval;
        }

        if (!in_critical) queue_mutex.lock();
        printf("capacity -> %d\n", capacity_);
        if (capacity_ > capacity)
        {
            wait_resize = 1;
            while ((!events[0].empty()) || (!events[1].empty()))
            {
                queue_mutex.unlock(); 
                std::this_thread::sleep_for(std::chrono::microseconds(10));
                queue_mutex.lock();
                for (int i=0; i<2; i++)
                if (retval = EventCheck(i, true))
                {
                    queue_mutex.unlock();
                    return retval;
                }
            }

            if (retval = array.EnsureSize(capacity_, true)) 
                return Combined_Return(retval, in_critical);
            for (SizeT i=0; i<num_vertex_associates; i++)
            {
                if (retval = vertex_associates[i].EnsureSize(capacity_, true))
                    return Combined_Return(retval, in_critical);
            }
            for (SizeT i=0; i<num_value__associates; i++)
            {
                if (retval = value__associates[i].EnsureSize(capacity_, true))
                    return Combined_Return(retval, in_critical);
            }

            if (tail_a + size_occu > capacity)
            {
                if (tail_a + size_occu > capacity_)
                { // Content cross original and new end point
                    SizeT lengths[2] = {0, 0};
                    lengths[0] = capacity_ - capacity;
                    lengths[1] = head_a - lengths[0];

                    if (retval = temp_array.EnsureSize(lengths[1], false, 0, allocated))
                        return Combined_Return(retval, in_critical);
                    if (num_value__associates != 0)
                    if (retval = temp_value__associates.EnsuerSize(lengths[1], false, 0, allocated))
                        return Combined_Return(retval, in_critical);

                    if (retval = array.Move_Out(allocated, allocated,
                        array       .GetPointer(allocated), lengths[0], 0, capacity))
                        return Combined_Return(retval, in_critical);
                    if (retval = array.Move_Out(allocated, allocated,
                        temp_array  .GetPointer(allocated), lengths[1], lengths[0], 0))
                        return Combined_Return(retval, in_critical);
                    if (retval = array.Move_In (allocated, allocated,
                        temp_array  .GetPointer(allocated), lengths[1], 0, 0))
                        return Combined_Return(retval, in_critical);

                    for (SizeT i=0; i<num_vertex_associates; i++)
                    {
                        if (retval = vertex_associates[i].Move_Out(allocated, allocated,
                            vertex_associates[i].GetPointer(allocated), lengths[0], 0, capacity))
                            return Combined_Return(retval, in_critical);
                        if (retval = vertex_associates[i].Move_Out(allocated, allocated,
                            temp_array .GetPointer(allocated), lengths[1], lengths[0], 0))
                            return Combined_Return(retval, in_critical);
                        if (retval = vertex_associates[i].Move_In (allocated, allocated,
                            temp_array .GetPointer(allocated), lengths[1], 0, 0))
                            return Combined_Return(retval, in_critical);
                    }
                    for (SizeT i=0; i<num_value__associates; i++)
                    {
                        if (retval = value__associates[i].Move_Out(allocated, allocated,
                            value__associates[i].GetPointer(allocated), lengths[0], 0, capacity))
                            return Combined_Return(retval, in_critical);
                        if (retval = value__associates[i].Move_Out(allocated, allocated,
                            temp_value__associates.GetPointer(allocated), lengths[1], lengths[0], 0))
                            return Combined_Return(retval, in_critical);
                        if (retval = value__associates[i].Move_In (allocated, allocated,
                            temp_value__associates.GetPointer(allocated), lengths[1], 0, 0))
                            return Combined_Return(retval, in_critical);
                    }
                   
                } else { // Content cross original end point, but not new end point
                    if (retval = array.Move_Out(allocated, allocated, 
                        array.GetPointer(allocated), head_a, 0, capacity)) 
                        return Combined_Return(retval, in_critical);
                    for (SizeT i=0; i<num_vertex_associates; i++)
                    {
                        if (retval = vertex_associates[i].Move_Out(allocated, allocated,
                            vertex_associates[i].GetPointer(allocated), head_a, 0, capacity))
                            return Combined_Return(retval, in_critical);
                    }
                    for (SizeT i=0; i<num_value__associates; i++)
                    {
                        if (retval = value__associates[i].Move_Out(allocated, allocated,
                            value__associates[i].GetPointer(allocated), head_a, 0, capacity))
                            return Combined_Return(retval, in_critical);
                    }
                }
            }

            capacity = capacity_;
            head_a = (tail_a + size_occu) % capacity;
            head_b = head_a;
            temp_array.Release();
            printf("EnsureCapacity: capacity -> %d, head_a -> %d\n", capacity, head_a);
            //fflush(stdout);
            wait_resize = 0;
        }
        if (!in_critical) queue_mutex.unlock();
        return retval;
    }

    void EventStart( int direction, SizeT offset, SizeT length, bool in_critical = false)
    {
        if (!in_critical) queue_mutex.lock();
        printf("Event %d,%d,%d starts\n", direction, offset, length);//fflush(stdout);
        events[direction].push_back(CqEvent(offset, length));
        if (!in_critical) queue_mutex.unlock();
    }

    cudaError_t EventSet(
        int   direction, 
        SizeT offset, 
        SizeT length, 
        cudaStream_t stream = 0, 
        bool in_critical = false)
    {
        cudaError_t retval = cudaSuccess;
        if (allocated != DEVICE) return retval;

        if (offset + length > capacity && direction == 0)
        { // single chunk crossing the end, and in event
            SizeT offsets[2] = {0, 0};
            SizeT lengths[2] = {0, 0};
            SizeT sum        = 0;
            offsets[0] = offset; offsets[1] = 0;
            lengths[0] = capacity - offset; lengths[1] = length - lengths[0];

            for (int i=0; i<2; i++)
            {
                if (lengths[i] == 0) continue;
                if (retval = array.Move_In(
                    allocated, allocated, temp_array.GetPointer(allocated), 
                    lengths[i], sum, offsets[i], stream)) return retval;
                for (SizeT j=0; j<num_vertex_associates; j++)
                {
                    if (retval = vertex_associates[j].Move_In(
                        allocated, allocated, temp_vertex_associates.GetPointer(allocated),
                        lengths[i], j*length + sum, offsets[i], stream)) return retval; 
                }
                for (SizeT j=0; j<num_value__associates; j++)
                {
                    if (retval = value__associates[j].Move_In(
                        allocated, allocated, temp_value__associates.GetPointer(allocated),
                        lengths[i], j*length + sum, offsets[i], stream)) return retval;
                }
            }
        }

        if (!in_critical) queue_mutex.lock();
 
        if (empty_gpu_events.empty())
        {
            retval = util::GRError(cudaErrorLaunchOutOfResources,
                (name + " gpu_events oversize ").c_str(), __FILE__, __LINE__);
            if (!in_critical) queue_mutex.unlock();
            return retval;    
        }
        cudaEvent_t event = empty_gpu_events.front();
        empty_gpu_events.pop_front();
        if (retval = cudaEventRecord(event, stream))
        {
            if (!in_critical) queue_mutex.unlock();
            return retval;
        }

        typename std::list<CqEvent>::iterator it = events[direction].begin();
        for (it  = events[direction].begin(); 
             it != events[direction].end(); it ++)
        {
            if ((offset == (*it).offset) && (length == (*it).length)) // matched event
            {
                printf("Event %d,%d,%d sets\n", direction, offset, length);//fflush(stdout);
                (*it).event = event;
                (*it).status = 1;
                break;
            }
        }
        EventCheck(direction, true);
        if (!in_critical) queue_mutex.unlock();
        return retval;
    }

    cudaError_t EventFinish(
        int   direction, 
        SizeT offset, 
        SizeT length, 
        bool  in_critical = false,
        cudaStream_t stream = 0)
    {
        cudaError_t retval = cudaSuccess;

        if (offset + length > capacity && direction == 0)
        { // single chunk crossing the end, and in event
            SizeT offsets[2] = {0, 0};
            SizeT lengths[2] = {0, 0};
            SizeT sum        = 0;
            offsets[0] = offset; offsets[1] = 0;
            lengths[0] = capacity - offset; lengths[1] = length - lengths[0];

            for (int i=0; i<2; i++)
            {
                if (lengths[i] == 0) continue;
                if (retval = array.Move_In(
                    allocated, allocated, temp_array.GetPointer(allocated), 
                    lengths[i], sum, offsets[i], stream)) return retval;
                for (SizeT j=0; j<num_vertex_associates; j++)
                {
                    if (retval = vertex_associates[j].Move_In(
                        allocated, allocated, temp_vertex_associates.GetPointer(allocated),
                        lengths[i], j*length + sum, offsets[i], stream)) return retval; 
                }
                for (SizeT j=0; j<num_value__associates; j++)
                {
                    if (retval = value__associates[j].Move_In(
                        allocated, allocated, temp_value__associates.GetPointer(allocated),
                        lengths[i], j*length + sum, offsets[i], stream)) return retval;
                }
            }
            if (allocated == DEVICE && stream != 0)
            {
                if (retval = GRError(cudaStreamSynchronize(stream),
                    name + "cudaStreamSynchronize failed", __FILE__, __LINE__)) return retval;
            }
        }

        if (!in_critical) queue_mutex.lock();
        typename std::list<CqEvent>::iterator it = events[direction].begin();
        for (it  = events[direction].begin(); 
             it != events[direction].end(); it ++)
        {
            if ((offset == (*it).offset) && (length == (*it).length)) // matched event
            {
                printf("Event %d,%d,%d finishes\n", direction, offset, length);//fflush(stdout);
                (*it).status = 2;
                break;
            }
        }
        SizeCheck(direction, true);
        ShowDebugInfo("EventF", direction, offset, -1, length);
        if (!in_critical) queue_mutex.unlock();
        return retval;
    }

    cudaError_t EventCheck(int direction, bool in_critical = false)
    {
        cudaError_t retval = cudaSuccess;
        if (!in_critical) queue_mutex.lock();

        typename std::list<CqEvent>::iterator it = events[direction].begin();
        for (it  = events[direction].begin();
             it != events[direction].end(); it++)
        {
            if ((*it).status == 1)
            {
                retval = cudaEventQuery((*it).event);
                if (retval == cudaSuccess)
                {
                    (*it).status = 2;
                    printf("Event %d,%d,%d finishes\n", direction, (*it).offset, (*it).length);
                    empty_gpu_events.push_back((*it).event);
                } else if (retval != cudaErrorNotReady) {
                    if (!in_critical) queue_mutex.unlock();
                    return retval;
                }
            }
        }
        SizeCheck(direction, true);
        ShowDebugInfo("EventC", direction, -1, -1, -1);
        if (!in_critical) queue_mutex.unlock();
        return retval; 
    }

    void SizeCheck(int direction, bool in_critical = false)
    {
        if (!in_critical) queue_mutex.lock();
        typename std::list<CqEvent>::iterator it = events[direction].begin();
       
        while (!events[direction].empty())
        {
            it = events[direction].begin();
            //printf("Event %d, %d, %d, status = %d\n", direction, (*it).offset, (*it).length, (*it).status);fflush(stdout);
            if ((*it).status == 2) // finished event
            {
                if (direction == 0)
                { // in event
                    if ((*it).offset == head_b)
                    {
                        head_b += (*it).length;
                        if (head_b >= capacity) head_b -= capacity;
                        (*it).status = 3;
                        size_soli += (*it).length;
                    } 
                } else { // out event
                    if ((*it).offset == tail_b)
                    {
                        tail_b += (*it).length;
                        if (tail_b >= capacity) tail_b -= capacity;
                        (*it).status = 3;
                        size_occu -= (*it).length;
                    }
                }
                events[direction].pop_front();
            } else {
                break;
            }
        }

        if (!in_critical) queue_mutex.unlock();
    }
}; // end of struct CircularQueue

} // namespace util
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:

