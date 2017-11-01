#ifndef CAFFE_SOFTMAXTREE_LAYER_HPP_
#define CAFFE_SOFTMAXTREE_LAYER_HPP_

#include <vector>

#include "caffe/blob.hpp"
#include "caffe/layer.hpp"
#include "caffe/proto/caffe.pb.h"

namespace caffe {

class Tree {
private:
    int* leaf_;
    int n_; // Total number of nodes in the tree
    int* parent_;
    int* child_;
    int* group_;
    char** name_;

    int groups_; // Number of groups in the tree
    int* group_size_cpu_ptr_;
    int* group_offset_cpu_ptr_;

public:
    Tree() : leaf_(NULL), parent_(NULL), child_(NULL),
        group_(NULL), name_(NULL), groups_(0),
        group_size_cpu_ptr_(NULL), group_offset_cpu_ptr_(NULL),
        group_size_(), group_offset_() {
    }
    void read(const char *filename);
    int groups() {
        return groups_;
    }
    int nodes() {
        return n_;
    }
    Blob<int> group_size_;
    Blob<int> group_offset_;
};

/**
 * @brief Computes the softmax function for a taxonomy tree of classes.
 *
 * This is a generalization of softmax (softmax is a tree with only a single group, all roots)
 * IOW softmaxtree can be interpreted as a softmax function that can operate on a dense matrix of sparse groups of channels 
 * (i.e. softmax_axis_ is the flattened sparse matrix).
 * Forward and backward are computed similar to softmax, but per-group of siblings
 */
template <typename Dtype>
class SoftmaxTreeLayer : public Layer<Dtype> {
 public:
  explicit SoftmaxTreeLayer(const LayerParameter& param)
      : Layer<Dtype>(param) {}
  virtual void LayerSetUp(
      const vector<Blob<Dtype>*>& bottom, const vector<Blob<Dtype>*>& top);
  virtual void Reshape(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);

  virtual inline const char* type() const { return "SoftmaxTree"; }
  virtual inline int ExactNumBottomBlobs() const { return 1; }
  virtual inline int ExactNumTopBlobs() const { return 1; }

 protected:
  virtual void Forward_cpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);
  virtual void Forward_gpu(const vector<Blob<Dtype>*>& bottom,
      const vector<Blob<Dtype>*>& top);
  virtual void Backward_cpu(const vector<Blob<Dtype>*>& top,
      const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom);
  virtual void Backward_gpu(const vector<Blob<Dtype>*>& top,
     const vector<bool>& propagate_down, const vector<Blob<Dtype>*>& bottom);

  int outer_num_;
  int inner_num_;
  int softmax_axis_;
  Tree softmax_tree_;
  /// sum_multiplier is used to carry out sum using BLAS
  Blob<Dtype> sum_multiplier_;
};

}  // namespace caffe

#endif  // CAFFE_SOFTMAXTREE_LAYER_HPP_
