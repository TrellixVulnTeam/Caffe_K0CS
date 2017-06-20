#include <algorithm>
#include <vector>
#include "cuda_runtime.h"
#include "curand.h"
#include "cublas_v2.h"
#include "cuda.h"

#include "caffe/layers/region_loss_layer.hpp"

namespace caffe {
#define BLOCK 512

dim3 cuda_gridsize(size_t n){
    size_t k = (n-1) / BLOCK + 1;
    size_t x = k;
    size_t y = 1;
    if(x > 65535){
        x = ceil(sqrt(k));
        y = (n-1)/(x*BLOCK) + 1;
    }
    dim3 d;
    d.x = (unsigned int)x;
    d.y = (unsigned int)y;
    d.z = 1;

    //printf("%ld %ld %ld %ld\n", n, x, y, x*y*BLOCK);
    return d;
}

__device__ void softmax_device(const float *input, int n, float temp, int stride, float *output)
{
    int i;
    float sum = 0;
    float largest = -INFINITY;
    for(i = 0; i < n; ++i){
        int val = input[i*stride];
        largest = (val>largest) ? val : largest;
    }
    for(i = 0; i < n; ++i){
        float e = exp(input[i*stride]/temp - largest/temp);
        sum += e;
        output[i*stride] = e;
    }
    for(i = 0; i < n; ++i){
        output[i*stride] /= sum;
    }
}

__global__ void softmax_kernel(const float *input, int n, int batch, int batch_offset, int groups, int group_offset, int stride, float temp, float *output)
{
    int id = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if (id >= batch*groups) return;
    int b = id / groups;
    int g = id % groups;
    softmax_device(input + b*batch_offset + g*group_offset, n, temp, stride, output + b*batch_offset + g*group_offset);
}

void softmax_gpu(const float *input, int n, int batch, int batch_offset, int groups, int group_offset, int stride, float temp, float *output)
{
    softmax_kernel<<<cuda_gridsize(batch*groups), BLOCK>>>(input, n, batch, batch_offset, groups, group_offset, stride, temp, output);
    CUDA_POST_KERNEL_CHECK;
}

__device__ float logistic_activate_kernel(float x) { return 1. / (1. + exp(-x)); }
__device__ float logistic_gradient_kernel(float x) { return (1 - x)*x; }

__device__ float activate_kernel(float x, ACTIVATION a)
{
    switch (a) {
    case LOGISTIC:
        return logistic_activate_kernel(x);
    }
    return 0;
}

__device__ float gradient_kernel(float x, ACTIVATION a)
{
    switch (a) {
    case LOGISTIC:
        return logistic_gradient_kernel(x);
    }
    return 0;
}

__global__ void activate_array_kernel(float *x, int n, ACTIVATION a)
{
    int i = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if (i < n) x[i] = activate_kernel(x[i], a);
}

__global__ void gradient_array_kernel(float *x, int n, ACTIVATION a, float *delta)
{
    int i = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if (i < n) delta[i] *= gradient_kernel(x[i], a);
}

void activate_array_ongpu(float *x, int n, ACTIVATION a)
{
    activate_array_kernel << <cuda_gridsize(n), BLOCK >> >(x, n, a);
    CUDA_POST_KERNEL_CHECK;
}

void gradient_array_ongpu(float *x, int n, ACTIVATION a, float *delta)
{
    gradient_array_kernel << <cuda_gridsize(n), BLOCK >> >(x, n, a, delta);
    CUDA_POST_KERNEL_CHECK;
}

__global__ void axpy_kernel(int N, float ALPHA, float *X, int OFFX, int INCX, float *Y, int OFFY, int INCY)
{
    int i = (blockIdx.x + blockIdx.y*gridDim.x) * blockDim.x + threadIdx.x;
    if (i < N) Y[OFFY + i*INCY] += ALPHA*X[OFFX + i*INCX];
}

void axpy_ongpu_offset(int N, float ALPHA, float * X, int OFFX, int INCX, float * Y, int OFFY, int INCY)
{
    axpy_kernel << <cuda_gridsize(N), BLOCK >> >(N, ALPHA, X, OFFX, INCX, Y, OFFY, INCY);
    CUDA_POST_KERNEL_CHECK;
}

void axpy_ongpu(int N, float ALPHA, float * X, int INCX, float * Y, int INCY)
{
    axpy_ongpu_offset(N, ALPHA, X, 0, INCX, Y, 0, INCY);
}

template <typename Dtype>
void RegionLossLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) {
    // prepare wrapper environment for forward computation
    network &net = this->net_;
    layer &l = this->l_;
    prepare_net_layer(net, l, bottom, top);
    net.input_gpu = (const float *)bottom[0]->gpu_data();
    if (this->phase_ == TEST)
        l.output_gpu = (float *)top[0]->mutable_gpu_data();
    else
        l.output_gpu = (float *)output_.mutable_gpu_data();
    
    // perform computation
    caffe_gpu_memcpy(l.outputs * l.batch * sizeof(float), net.input_gpu, l.output_gpu);
    for (int b = 0; b < l.batch; ++b) {
        for (int n = 0; n < l.n; ++n) {
            int index = entry_index(l, b, n*l.w*l.h, 0);
            activate_array_ongpu(l.output_gpu + index, 2 * l.w*l.h, LOGISTIC);
            index = entry_index(l, b, n*l.w*l.h, 4);
            activate_array_ongpu(l.output_gpu + index, l.w*l.h, LOGISTIC);
        }
    }
    if (l.softmax_tree) {
        int i;
        int count = 5;
        for (i = 0; i < l.softmax_tree->groups; ++i) {
            int group_size = l.softmax_tree->group_size[i];
            int index = entry_index(l, 0, 0, count);
            softmax_gpu(net.input_gpu + index, group_size, l.batch*l.n, l.inputs / l.n, l.w*l.h, 1, l.w*l.h, 1, l.output_gpu + index);
            count += group_size;
        }
    }
    else if (l.softmax) {
        int index = entry_index(l, 0, 0, 5);
        //printf("%d\n", index);
        softmax_gpu(net.input_gpu + index, l.classes, l.batch*l.n, l.inputs / l.n, l.w*l.h, 1, l.w*l.h, 1, l.output_gpu + index);
    }

    if (this->phase_ == TEST) return;

    // copy data from gpu to cpu and compute the remaining part for loss
    net.input = (const float *)bottom[0]->cpu_data();
    l.output = (float *)output_.mutable_cpu_data();
    forward_for_loss(net, l);
}

template <typename Dtype>
void RegionLossLayer<Dtype>::Backward_gpu(const vector<Blob<Dtype>*>& top,
    const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom) {
    // prepare wrapper environment for forward computation
    network &net = this->net_;
    layer &l = this->l_;
    prepare_net_layer(net, l, bottom, top);
    l.output_gpu = (float *)output_.mutable_gpu_data();
    l.delta_gpu = (float *)bottom[0]->mutable_gpu_diff();
    caffe_gpu_memcpy(l.outputs * l.batch * sizeof(float), output_.gpu_diff(), l.delta_gpu);

    for (int b = 0; b < l.batch; ++b) {
        for (int n = 0; n < l.n; ++n) {
            int index = entry_index(l, b, n*l.w*l.h, 0);
            gradient_array_ongpu(l.output_gpu + index, 2 * l.w*l.h, LOGISTIC, l.delta_gpu + index);
            index = entry_index(l, b, n*l.w*l.h, 4);
            gradient_array_ongpu(l.output_gpu + index, l.w*l.h, LOGISTIC, l.delta_gpu + index);
        }
    }
}

INSTANTIATE_LAYER_GPU_FUNCS(RegionLossLayer);

template <typename Dtype>
void RegionOutputLayer<Dtype>::Forward_gpu(const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top) {
    layer &l = this->l_;
    l.output_gpu = (float *)output_.mutable_gpu_data();
    network net;
    net.input_gpu = (float *)bottom[0]->gpu_data();

    // As in RegionLossLayer, apply sigmoid or softmax operations on bottom data.
    caffe_gpu_memcpy(l.outputs * l.batch * sizeof(float), net.input_gpu, l.output_gpu);
    for (int b = 0; b < l.batch; ++b) {
        for (int n = 0; n < l.n; ++n) {
            int index = entry_index(l, b, n*l.w*l.h, 0);
            activate_array_ongpu(l.output_gpu + index, 2 * l.w*l.h, LOGISTIC);
            index = entry_index(l, b, n*l.w*l.h, 4);
            activate_array_ongpu(l.output_gpu + index, l.w*l.h, LOGISTIC);
        }
    }
    if (l.softmax_tree) {
        int count = 5;
        for (int i = 0; i < l.softmax_tree->groups; ++i) {
            int group_size = l.softmax_tree->group_size[i];
            int index = entry_index(l, 0, 0, count);
            softmax_gpu(net.input_gpu + index, group_size, l.batch*l.n, l.inputs / l.n, l.w*l.h, 1, l.w*l.h, 1, l.output_gpu + index);
            count += group_size;
        }
    }
    else if (l.softmax) {
        int index = entry_index(l, 0, 0, 5);
        //printf("%d\n", index);
        softmax_gpu(net.input_gpu + index, l.classes, l.batch*l.n, l.inputs / l.n, l.w*l.h, 1, l.w*l.h, 1, l.output_gpu + index);
    }

    GetRegionBoxes(bottom, top);
}

INSTANTIATE_LAYER_GPU_FUNCS(RegionOutputLayer);
}  // namespace caffe
