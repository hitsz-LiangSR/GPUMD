/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "model/box.cuh"
#include "nep4.cuh"
#include "utilities/common.cuh"
#include "utilities/nep_utilities.cuh"

#if defined(__CUDA_ARCH__) && (__CUDA_ARCH__ < 600)
static __device__ __inline__ double atomicAdd(double* address, double val)
{
  unsigned long long* address_as_ull = (unsigned long long*)address;
  unsigned long long old = *address_as_ull, assumed;
  do {
    assumed = old;
    old =
      atomicCAS(address_as_ull, assumed, __double_as_longlong(val + __longlong_as_double(assumed)));

  } while (assumed != old);
  return __longlong_as_double(old);
}
#endif

static __device__ void apply_mic_small_box(
  const Box& box, const NEP4::ExpandedBox& ebox, double& x12, double& y12, double& z12)
{
  if (box.triclinic == 0) {
    if (box.pbc_x == 1 && x12 < -ebox.h[3]) {
      x12 += ebox.h[0];
    } else if (box.pbc_x == 1 && x12 > +ebox.h[3]) {
      x12 -= ebox.h[0];
    }
    if (box.pbc_y == 1 && y12 < -ebox.h[4]) {
      y12 += ebox.h[1];
    } else if (box.pbc_y == 1 && y12 > +ebox.h[4]) {
      y12 -= ebox.h[1];
    }
    if (box.pbc_z == 1 && z12 < -ebox.h[5]) {
      z12 += ebox.h[2];
    } else if (box.pbc_z == 1 && z12 > +ebox.h[5]) {
      z12 -= ebox.h[2];
    }
  } else {
    double sx12 = ebox.h[9] * x12 + ebox.h[10] * y12 + ebox.h[11] * z12;
    double sy12 = ebox.h[12] * x12 + ebox.h[13] * y12 + ebox.h[14] * z12;
    double sz12 = ebox.h[15] * x12 + ebox.h[16] * y12 + ebox.h[17] * z12;
    if (box.pbc_x == 1)
      sx12 -= nearbyint(sx12);
    if (box.pbc_y == 1)
      sy12 -= nearbyint(sy12);
    if (box.pbc_z == 1)
      sz12 -= nearbyint(sz12);
    x12 = ebox.h[0] * sx12 + ebox.h[1] * sy12 + ebox.h[2] * sz12;
    y12 = ebox.h[3] * sx12 + ebox.h[4] * sy12 + ebox.h[5] * sz12;
    z12 = ebox.h[6] * sx12 + ebox.h[7] * sy12 + ebox.h[8] * sz12;
  }
}

static __global__ void find_neighbor_list_small_box(
  NEP4::ParaMB paramb,
  const int N,
  const int N1,
  const int N2,
  const Box box,
  const NEP4::ExpandedBox ebox,
  const double* __restrict__ g_x,
  const double* __restrict__ g_y,
  const double* __restrict__ g_z,
  int* g_NN_angular,
  int* g_NL_angular,
  float* g_x12_angular,
  float* g_y12_angular,
  float* g_z12_angular)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    double x1 = g_x[n1];
    double y1 = g_y[n1];
    double z1 = g_z[n1];
    int count_angular = 0;
    for (int n2 = N1; n2 < N2; ++n2) {
      for (int ia = 0; ia < ebox.num_cells[0]; ++ia) {
        for (int ib = 0; ib < ebox.num_cells[1]; ++ib) {
          for (int ic = 0; ic < ebox.num_cells[2]; ++ic) {
            if (ia == 0 && ib == 0 && ic == 0 && n1 == n2) {
              continue; // exclude self
            }

            double delta[3];
            if (box.triclinic) {
              delta[0] = box.cpu_h[0] * ia + box.cpu_h[1] * ib + box.cpu_h[2] * ic;
              delta[1] = box.cpu_h[3] * ia + box.cpu_h[4] * ib + box.cpu_h[5] * ic;
              delta[2] = box.cpu_h[6] * ia + box.cpu_h[7] * ib + box.cpu_h[8] * ic;
            } else {
              delta[0] = box.cpu_h[0] * ia;
              delta[1] = box.cpu_h[1] * ib;
              delta[2] = box.cpu_h[2] * ic;
            }

            double x12 = g_x[n2] + delta[0] - x1;
            double y12 = g_y[n2] + delta[1] - y1;
            double z12 = g_z[n2] + delta[2] - z1;

            apply_mic_small_box(box, ebox, x12, y12, z12);

            float distance_square = float(x12 * x12 + y12 * y12 + z12 * z12);
            if (distance_square < paramb.rc_angular * paramb.rc_angular) {
              g_NL_angular[count_angular * N + n1] = n2;
              g_x12_angular[count_angular * N + n1] = float(x12);
              g_y12_angular[count_angular * N + n1] = float(y12);
              g_z12_angular[count_angular * N + n1] = float(z12);
              count_angular++;
            }
          }
        }
      }
    }
    g_NN_angular[n1] = count_angular;
  }
}

static __global__ void find_descriptor_small_box(
  NEP4::ParaMB paramb,
  NEP4::ANN ann,
  const int N,
  const int N1,
  const int N2,
  const int* g_NN_angular,
  const int* g_NL_angular,
  const int* __restrict__ g_type,
  const float* __restrict__ g_x12_angular,
  const float* __restrict__ g_y12_angular,
  const float* __restrict__ g_z12_angular,
  double* g_q,
  double* g_s)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    int t1 = g_type[n1];
    float q[MAX_DIM] = {0.0f};

    // get angular descriptors
    for (int n = 0; n <= paramb.n_max_angular; ++n) {
      float s[NUM_OF_ABC] = {0.0f};
      for (int i1 = 0; i1 < g_NN_angular[n1]; ++i1) {
        int index = i1 * N + n1;
        int n2 = g_NL_angular[index];
        float r12[3] = {g_x12_angular[index], g_y12_angular[index], g_z12_angular[index]};
        float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
        float fc12;
        find_fc(paramb.rc_angular, paramb.rcinv_angular, d12, fc12);
        int t2 = g_type[n2];
        float fn12[MAX_NUM_N];
        find_fn(paramb.basis_size, paramb.rcinv_angular, d12, fc12, fn12);
        float gn12 = 0.0f;
        for (int k = 0; k <= paramb.basis_size; ++k) {
          int c_index = (n * (paramb.basis_size + 1) + k) * paramb.num_types_sq;
          c_index += t1 * paramb.num_types + t2;
          gn12 += fn12[k] * ann.c[c_index];
        }
        accumulate_s(d12, r12[0], r12[1], r12[2], gn12, s);
      }
      find_q(paramb.n_max_angular + 1, n, s, q);
      for (int abc = 0; abc < NUM_OF_ABC; ++abc) {
        g_s[(n * NUM_OF_ABC + abc) * N + n1] = s[abc];
      }
    }
    for (int n = 0; n <= paramb.n_max_angular; ++n) {
      for (int l = 0; l < paramb.L_max; ++l) {
        int ln = l * (paramb.n_max_angular + 1) + n;
        g_q[n1 + ln * N] = q[ln];
      }
    }
  }
}

static __global__ void find_dq_dr_small_box(
  const int N,
  const int* g_NN,
  const int* g_NL,
  const NEP4::ParaMB para,
  const NEP4::ANN ann,
  const int* __restrict__ g_type,
  const double* __restrict__ g_x12,
  const double* __restrict__ g_y12,
  const double* __restrict__ g_z12,
  const double* __restrict__ g_s,
  double* g_dq_dx,
  double* g_dq_dy,
  double* g_dq_dz)
{
  int n1 = threadIdx.x + blockIdx.x * blockDim.x;
  if (n1 < N) {
    float s[NUM_OF_ABC * MAX_NUM_N];
    for (int d = 0; d < (para.n_max_angular + 1) * NUM_OF_ABC; ++d) {
      s[d] = g_s[d * N + n1];
    }
    int neighbor_number = g_NN[n1];
    int t1 = g_type[n1];
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int index = i1 * N + n1;
      int n2 = g_NL[index];
      float r12[3] = {g_x12[index], g_y12[index], g_z12[index]};
      float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
      float fc12, fcp12;
      find_fc_and_fcp(para.rc_angular, para.rcinv_angular, d12, fc12, fcp12);
      int t2 = g_type[n2];
      float fn12[MAX_NUM_N];
      float fnp12[MAX_NUM_N];
      find_fn_and_fnp(para.basis_size, para.rcinv_angular, d12, fc12, fcp12, fn12, fnp12);
      for (int n = 0; n <= para.n_max_angular; ++n) {
        float gn12 = 0.0f;
        float gnp12 = 0.0f;
        for (int k = 0; k <= para.basis_size; ++k) {
          int c_index = (n * (para.basis_size + 1) + k) * para.num_types_sq;
          c_index += t1 * para.num_types + t2;
          gn12 += fn12[k] * ann.c[c_index];
          gnp12 += fnp12[k] * ann.c[c_index];
        }
        dq_dr_double(
          N * (i1 * ann.dim + n) + n1, N * (para.n_max_angular + 1), n, para.n_max_angular + 1, d12,
          r12, gn12, gnp12, s, g_dq_dx, g_dq_dy, g_dq_dz);
      }
    }
  }
}

// Precompute messages q*theta for all descriptors
static __global__ void apply_gnn_compute_messages_small_box(
  const int N,
  const NEP4::ANN ann,
  const NEP4::GNN gnn,
  const double* __restrict__ g_q,
  const double* __restrict__ dq_dx,
  const double* __restrict__ dq_dy,
  const double* __restrict__ dq_dz,
  const int* g_NN,
  const int* g_NL,
  double* gnn_messages,
  double* gnn_messages_p_x,
  double* gnn_messages_p_y,
  double* gnn_messages_p_z)
{
  int n1 = threadIdx.x + blockIdx.x * blockDim.x;
  if (n1 < N) {
    int num_neighbors_of_n1 = g_NN[n1];
    const int F = ann.dim; // dimension of q_out, for now dim_out = dim_in.
    for (int nu = 0; nu < F; nu++) {
      float q_theta_nu = 0.0f;
      for (int gamma = 0; gamma < ann.dim; gamma++) {
        q_theta_nu += g_q[n1 + gamma * N] * gnn.theta[gamma + ann.dim * nu];
      }
      for (int j = 0; j < num_neighbors_of_n1; ++j) {
        // int index_j = n1 + N * j;
        // int n2 = g_NL[index_j];
        float dq_drij_x = 0.0f;
        float dq_drij_y = 0.0f;
        float dq_drij_z = 0.0f;
        for (int gamma = 0; gamma < ann.dim; gamma++) {
          dq_drij_x += dq_dx[N * (j * ann.dim + gamma) + n1] * gnn.theta[gamma + ann.dim * nu];
          dq_drij_y += dq_dy[N * (j * ann.dim + gamma) + n1] * gnn.theta[gamma + ann.dim * nu];
          dq_drij_z += dq_dz[N * (j * ann.dim + gamma) + n1] * gnn.theta[gamma + ann.dim * nu];
        }
        gnn_messages_p_x[N * (nu * MAX_NEIGHBORS + j) + n1] = dq_drij_x;
        gnn_messages_p_y[N * (nu * MAX_NEIGHBORS + j) + n1] = dq_drij_y;
        gnn_messages_p_z[N * (nu * MAX_NEIGHBORS + j) + n1] = dq_drij_z;
      }
      gnn_messages[n1 + nu * N] = q_theta_nu;
    }
  }
}

static __global__ void apply_gnn_message_passing_small_box(
  const int N,
  const NEP4::ParaMB para,
  const NEP4::ANN ann,
  const double* __restrict__ g_x12,
  const double* __restrict__ g_y12,
  const double* __restrict__ g_z12,
  const double* __restrict__ g_messages,
  const int* g_NN,
  const int* g_NL,
  double* gnn_descriptors,
  double* g_dU_dq)
{
  int n1 = threadIdx.x + blockIdx.x * blockDim.x;
  if (n1 < N) {
    int num_neighbors_of_n1 = g_NN[n1];
    const int F = ann.dim; // dimension of q_out, for now dim_out = dim_in.
    for (int nu = 0; nu < F; nu++) {
      float q_i_nu = g_messages[n1 + nu * N]; // fc(r_ii) = 1

      // TODO perhaps normalize weights? Compare Kipf, Welling et al. (2016)
      for (int j = 0; j < num_neighbors_of_n1; ++j) {
        int index_j = n1 + N * j;
        int n2 = g_NL[index_j];
        float r12[3] = {g_x12[index_j], g_y12[index_j], g_z12[index_j]};
        float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
        float fcij, fcpij;
        find_fc_and_fcp(para.rc_angular, para.rcinv_angular, d12, fcij, fcpij);
        q_i_nu += fcij * g_messages[n2 + nu * N];
      }
      gnn_descriptors[n1 + nu * N] = tanh(q_i_nu);
      g_dU_dq[n1 + nu * N] =
        1 - q_i_nu * q_i_nu; // save sigma'(zi) for when computing message passing forces later
    }
  }
}

static __global__ void apply_ann_small_box(
  const int N, const NEP4::ANN ann, const double* __restrict__ g_q, double* g_pe, double* g_dU_dq)
{
  int n1 = threadIdx.x + blockIdx.x * blockDim.x;
  if (n1 < N) {
    float q[MAX_DIM] = {0.0f};
    for (int d = 0; d < ann.dim; ++d) {
      q[d] = g_q[n1 + d * N];
    }
    float U = 0.0f, dU_dq[MAX_DIM] = {0.0f};
    apply_ann_one_layer(ann.dim, ann.num_neurons1, ann.w0, ann.b0, ann.w1, ann.b1, q, U, dU_dq);
    g_pe[n1] = U;
    for (int d = 0; d < ann.dim; ++d) {
      g_dU_dq[n1 + d * N] *= dU_dq[d];
    }
  }
}

static __global__ void zero_force_small_box(const int N, double* g_fx, double* g_fy, double* g_fz)
{
  int n1 = threadIdx.x + blockIdx.x * blockDim.x;
  if (n1 < N) {
    g_fx[n1] = 0.0;
    g_fy[n1] = 0.0;
    g_fz[n1] = 0.0;
  }
}

static __global__ void find_force_gnn_small_box(
  const int N,
  const NEP4::ParaMB para,
  const NEP4::ANN ann,
  const Box box,
  const NEP4::ExpandedBox ebox,
  const float* __restrict__ g_x12,
  const float* __restrict__ g_y12,
  const float* __restrict__ g_z12,
  const double* __restrict__ g_messages,
  const double* __restrict__ g_messages_p_x,
  const double* __restrict__ g_messages_p_y,
  const double* __restrict__ g_messages_p_z,
  const double* __restrict__ g_dU_dq,
  const int* g_NN,
  const int* g_NL,
  double* g_fx,
  double* g_fy,
  double* g_fz)
{
  int n1 = threadIdx.x + blockIdx.x * blockDim.x;
  if (n1 < N) {
    int num_neighbors_of_n1 = g_NN[n1];
    const int F = ann.dim; // dimension of q_out, for now dim_out = dim_in.
    for (int nu = 0; nu < F; nu++) {
      float f_i_x = 0.0f;
      float f_i_y = 0.0f;
      float f_i_z = 0.0f;

      float f_j_x = 0.0f;
      float f_j_y = 0.0f;
      float f_j_z = 0.0f;

      float f_k_x = 0.0f;
      float f_k_y = 0.0f;
      float f_k_z = 0.0f;

      for (int j = 0; j < num_neighbors_of_n1; ++j) {
        int index_j = n1 + N * j;
        int n2 = g_NL[index_j];

        // Fetch index i for atom n1 as a neighbor of n2
        int num_neighbors_of_n2 = g_NN[n2];
        int n2_i = -1;
        for (int n2_j = 0; n2_j < num_neighbors_of_n2; n2_j++) {
          int n2_neighbor = g_NL[n2 + N * n2_j];
          if (n2_neighbor == n1) {
            n2_i = n2_j;
            break;
          }
        }

        float r12[3] = {g_x12[index_j], g_y12[index_j], g_z12[index_j]};
        float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
        float fcij, fcpij;
        find_fc_and_fcp(para.rc_angular, para.rcinv_angular, d12, fcij, fcpij);
        f_i_x += g_messages_p_x[N * (j + nu * MAX_NEIGHBORS) + n1];
        f_i_y += g_messages_p_y[N * (j + nu * MAX_NEIGHBORS) + n1];
        f_i_z += g_messages_p_z[N * (j + nu * MAX_NEIGHBORS) + n1];
        f_i_x += fcij * g_messages_p_x[N * (n2_i + nu * MAX_NEIGHBORS) + n2];
        f_i_y += fcij * g_messages_p_y[N * (n2_i + nu * MAX_NEIGHBORS) + n2];
        f_i_z += fcij * g_messages_p_z[N * (n2_i + nu * MAX_NEIGHBORS) + n2];
        f_i_x += fcpij * g_messages[n2 + nu * N] * r12[0] / d12;
        f_i_y += fcpij * g_messages[n2 + nu * N] * r12[1] / d12;
        f_i_z += fcpij * g_messages[n2 + nu * N] * r12[2] / d12;

        f_j_x += g_messages_p_x[N * (n2_i + nu * MAX_NEIGHBORS) + n2];
        f_j_y += g_messages_p_y[N * (n2_i + nu * MAX_NEIGHBORS) + n2];
        f_j_z += g_messages_p_z[N * (n2_i + nu * MAX_NEIGHBORS) + n2];
        f_j_x += fcij * g_messages_p_x[N * (j + nu * MAX_NEIGHBORS) + n1]; // fcij = fcji
        f_j_y += fcij * g_messages_p_y[N * (j + nu * MAX_NEIGHBORS) + n1];
        f_j_z += fcij * g_messages_p_z[N * (j + nu * MAX_NEIGHBORS) + n1];
        f_j_x -= fcpij * g_messages[n2 + nu * N] * r12[0] / d12; // \vec{r}_ij = -\vec{r}_ji
        f_j_y -= fcpij * g_messages[n2 + nu * N] * r12[1] / d12;
        f_j_z -= fcpij * g_messages[n2 + nu * N] * r12[2] / d12;

        for (int k = 0; k < num_neighbors_of_n1; ++k) {
          if (k != j) {
            int index_k = n1 + N * k;
            int n3 = g_NL[index_k];
            // get rjk
            float r23[3] = {g_x12[index_k], g_y12[index_k], g_z12[index_k]};
            float d23 = sqrt(r23[0] * r23[0] + r23[1] * r23[1] + r23[2] * r23[2]);
            float fcjk;
            find_fc(para.rc_angular, para.rcinv_angular, d23, fcjk);
            // Fetch index i for atom n1 as a neighbor of n3
            int num_neighbors_of_n3 = g_NN[n3];
            int n3_i = -1;
            for (int n3_j = 0; n3_j < num_neighbors_of_n3; n3_j++) {
              int n3_neighbor = g_NL[n3 + N * n3_j];
              if (n3_neighbor == n1) {
                n3_i = n3_j;
                break;
              }
            }
            f_k_x += fcjk * g_messages_p_x[N * (n3_i + nu * MAX_NEIGHBORS) + n3] -
                     fcij * g_messages_p_x[N * (k + nu * MAX_NEIGHBORS) + n1];
            f_k_y += fcjk * g_messages_p_y[N * (n3_i + nu * MAX_NEIGHBORS) + n3] -
                     fcij * g_messages_p_y[N * (k + nu * MAX_NEIGHBORS) + n1];
            f_k_z += fcjk * g_messages_p_z[N * (n3_i + nu * MAX_NEIGHBORS) + n3] -
                     fcij * g_messages_p_z[N * (k + nu * MAX_NEIGHBORS) + n1];
          }
        }
        g_fx[n1] -= g_dU_dq[n2 + nu * N] * (f_j_x + f_k_x);
        g_fy[n1] -= g_dU_dq[n2 + nu * N] * (f_j_y + f_k_y);
        g_fz[n1] -= g_dU_dq[n2 + nu * N] * (f_j_z + f_k_z);
      }
      // sum forces over nu
      g_fx[n1] += g_dU_dq[n1 + nu * N] * f_i_x;
      g_fy[n1] += g_dU_dq[n1 + nu * N] * f_i_y;
      g_fz[n1] += g_dU_dq[n1 + nu * N] * f_i_z;
    }
  }
}

// static __global__ void find_force_angular_small_box(
//   NEP4::ParaMB paramb,
//   NEP4::ANN annmb,
//   const int N,
//   const int N1,
//   const int N2,
//   const int* g_NN_angular,
//   const int* g_NL_angular,
//   const int* __restrict__ g_type,
//   const float* __restrict__ g_x12,
//   const float* __restrict__ g_y12,
//   const float* __restrict__ g_z12,
//   const float* __restrict__ g_Fp,
//   const float* __restrict__ g_sum_fxyz,
//   double* g_fx,
//   double* g_fy,
//   double* g_fz,
//   double* g_virial)
// {
//   int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
//   if (n1 < N2) {

//     float Fp[MAX_DIM_ANGULAR] = {0.0f};
//     float sum_fxyz[NUM_OF_ABC * MAX_NUM_N];
//     for (int d = 0; d < (paramb.n_max_angular + 1) * paramb.L_max; ++d) {
//       Fp[d] = g_Fp[d * N + n1];
//     }
//     for (int d = 0; d < (paramb.n_max_angular + 1) * NUM_OF_ABC; ++d) {
//       sum_fxyz[d] = g_sum_fxyz[d * N + n1];
//     }

//     int t1 = g_type[n1];
//     float s_sxx = 0.0f;
//     float s_sxy = 0.0f;
//     float s_sxz = 0.0f;
//     float s_syx = 0.0f;
//     float s_syy = 0.0f;
//     float s_syz = 0.0f;
//     float s_szx = 0.0f;
//     float s_szy = 0.0f;
//     float s_szz = 0.0f;

//     for (int i1 = 0; i1 < g_NN_angular[n1]; ++i1) {
//       int index = i1 * N + n1;
//       int n2 = g_NL_angular[n1 + N * i1];
//       float r12[3] = {g_x12[index], g_y12[index], g_z12[index]};
//       float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
//       float fc12, fcp12;
//       find_fc_and_fcp(paramb.rc_angular, paramb.rcinv_angular, d12, fc12, fcp12);
//       int t2 = g_type[n2];
//       float f12[3] = {0.0f};

//       float fn12[MAX_NUM_N];
//       float fnp12[MAX_NUM_N];
//       find_fn_and_fnp(paramb.basis_size, paramb.rcinv_angular, d12, fc12, fcp12, fn12, fnp12);

//       for (int n = 0; n <= paramb.n_max_angular; ++n) {
//         float gn12 = 0.0f;
//         float gnp12 = 0.0f;
//         for (int k = 0; k <= paramb.basis_size; ++k) {
//           int c_index = (n * (paramb.basis_size + 1) + k) * paramb.num_types_sq;
//           c_index += t1 * paramb.num_types + t2;
//           gn12 += fn12[k] * annmb.c[c_index];
//           gnp12 += fnp12[k] * annmb.c[c_index];
//         }
//         accumulate_f12(n, paramb.n_max_angular + 1, d12, r12, gn12, gnp12, Fp, sum_fxyz, f12);
//       }
//       atomicAdd(&g_fx[n1], double(f12[0]));
//       atomicAdd(&g_fy[n1], double(f12[1]));
//       atomicAdd(&g_fz[n1], double(f12[2]));
//       atomicAdd(&g_fx[n2], double(-f12[0]));
//       atomicAdd(&g_fy[n2], double(-f12[1]));
//       atomicAdd(&g_fz[n2], double(-f12[2]));
//       s_sxx -= r12[0] * f12[0];
//       s_sxy -= r12[0] * f12[1];
//       s_sxz -= r12[0] * f12[2];
//       s_syx -= r12[1] * f12[0];
//       s_syy -= r12[1] * f12[1];
//       s_syz -= r12[1] * f12[2];
//       s_szx -= r12[2] * f12[0];
//       s_szy -= r12[2] * f12[1];
//       s_szz -= r12[2] * f12[2];
//     }
//     // save virial
//     // xx xy xz    0 3 4
//     // yx yy yz    6 1 5
//     // zx zy zz    7 8 2
//     g_virial[n1 + 0 * N] += s_sxx;
//     g_virial[n1 + 1 * N] += s_syy;
//     g_virial[n1 + 2 * N] += s_szz;
//     g_virial[n1 + 3 * N] += s_sxy;
//     g_virial[n1 + 4 * N] += s_sxz;
//     g_virial[n1 + 5 * N] += s_syz;
//     g_virial[n1 + 6 * N] += s_syx;
//     g_virial[n1 + 7 * N] += s_szx;
//     g_virial[n1 + 8 * N] += s_szy;
//   }
// }

static __global__ void find_force_ZBL_small_box(
  const int N,
  const NEP4::ZBL zbl,
  const int N1,
  const int N2,
  const int* g_NN,
  const int* g_NL,
  const int* __restrict__ g_type,
  const float* __restrict__ g_x12,
  const float* __restrict__ g_y12,
  const float* __restrict__ g_z12,
  double* g_fx,
  double* g_fy,
  double* g_fz,
  double* g_virial,
  double* g_pe)
{
  int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
  if (n1 < N2) {
    float s_pe = 0.0f;
    float s_sxx = 0.0f;
    float s_sxy = 0.0f;
    float s_sxz = 0.0f;
    float s_syx = 0.0f;
    float s_syy = 0.0f;
    float s_syz = 0.0f;
    float s_szx = 0.0f;
    float s_szy = 0.0f;
    float s_szz = 0.0f;
    float zi = zbl.atomic_numbers[g_type[n1]];
    float pow_zi = pow(zi, 0.23f);
    for (int i1 = 0; i1 < g_NN[n1]; ++i1) {
      int index = i1 * N + n1;
      int n2 = g_NL[index];
      float r12[3] = {g_x12[index], g_y12[index], g_z12[index]};
      float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
      float d12inv = 1.0f / d12;
      float f, fp;
      float zj = zbl.atomic_numbers[g_type[n2]];
      float a_inv = (pow_zi + pow(zj, 0.23f)) * 2.134563f;
      float zizj = K_C_SP * zi * zj;
      find_f_and_fp_zbl(zizj, a_inv, zbl.rc_inner, zbl.rc_outer, d12, d12inv, f, fp);
      float f2 = fp * d12inv * 0.5f;
      float f12[3] = {r12[0] * f2, r12[1] * f2, r12[2] * f2};
      atomicAdd(&g_fx[n1], double(f12[0]));
      atomicAdd(&g_fy[n1], double(f12[1]));
      atomicAdd(&g_fz[n1], double(f12[2]));
      atomicAdd(&g_fx[n2], double(-f12[0]));
      atomicAdd(&g_fy[n2], double(-f12[1]));
      atomicAdd(&g_fz[n2], double(-f12[2]));
      s_sxx -= r12[0] * f12[0];
      s_sxy -= r12[0] * f12[1];
      s_sxz -= r12[0] * f12[2];
      s_syx -= r12[1] * f12[0];
      s_syy -= r12[1] * f12[1];
      s_syz -= r12[1] * f12[2];
      s_szx -= r12[2] * f12[0];
      s_szy -= r12[2] * f12[1];
      s_szz -= r12[2] * f12[2];
      s_pe += f * 0.5f;
    }
    g_virial[n1 + 0 * N] += s_sxx;
    g_virial[n1 + 1 * N] += s_syy;
    g_virial[n1 + 2 * N] += s_szz;
    g_virial[n1 + 3 * N] += s_sxy;
    g_virial[n1 + 4 * N] += s_sxz;
    g_virial[n1 + 5 * N] += s_syz;
    g_virial[n1 + 6 * N] += s_syx;
    g_virial[n1 + 7 * N] += s_szx;
    g_virial[n1 + 8 * N] += s_szy;
    g_pe[n1] += s_pe;
  }
}
