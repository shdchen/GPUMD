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





#include "neighbor.cuh"
#include "neighbor_ON1.cuh"
#include "neighbor_ON2.cuh"
#include "atom.cuh"
#include "memory.cuh"
#include "error.cuh"
#include "parameters.cuh"

#define BLOCK_SIZE 128
#define DIM 3
#ifdef USE_DP
    #define HALF  0.5
#else
    #define HALF  0.5f
#endif



// When the number of cells (bins) is smaller than this value, 
/// use the O(N^2) method instead of the O(N) method
#define NUM_OF_CELLS 50




static __device__ void warp_reduce(volatile int *s, int t) 
{
    s[t] += s[t + 32]; s[t] += s[t + 16]; s[t] += s[t + 8];
    s[t] += s[t + 4];  s[t] += s[t + 2];  s[t] += s[t + 1];
}




// the first step for determining whether a new neighbor list should be built
static __global__ void check_atom_distance_1
(
    int N, real d2, real *x_old, real *y_old, real *z_old,
    real *x_new, real *y_new, real *z_new, int *g_sum
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int n = bid * blockDim.x + tid;
    
    __shared__ int s_sum[1024];
    s_sum[tid] = 0;
    
    if (n < N)
    {
        real dx = x_new[n] - x_old[n];
        real dy = y_new[n] - y_old[n];
        real dz = z_new[n] - z_old[n];
        if ( (dx * dx + dy * dy + dz * dz) > d2)
        {
            s_sum[tid] = 1;
        }
    }
    
    __syncthreads();
    if (tid < 512) s_sum[tid] += s_sum[tid + 512]; __syncthreads();
    if (tid < 256) s_sum[tid] += s_sum[tid + 256]; __syncthreads();
    if (tid < 128) s_sum[tid] += s_sum[tid + 128]; __syncthreads();
    if (tid <  64) s_sum[tid] += s_sum[tid + 64];  __syncthreads();
    if (tid <  32) warp_reduce(s_sum, tid); 
    
    if (tid ==  0) 
    {
        g_sum[bid] = s_sum[0]; 
    }
}




// the second step for determining whether a new neighbor list should be built
static __global__ void check_atom_distance_2(int M, int *g_sum_i, int *g_sum_o)
{
    int tid = threadIdx.x;
    int number_of_patches = (M - 1) / 1024 + 1; 
    
    __shared__ int s_sum[1024];
    s_sum[tid] = 0;
    
    for (int patch = 0; patch < number_of_patches; ++patch)
    { 
        int n = tid + patch * 1024;
        if (n < M)
        {        
            s_sum[tid] += g_sum_i[n];
        }
    }
    
    __syncthreads();
    if (tid < 512) s_sum[tid] += s_sum[tid + 512]; __syncthreads();
    if (tid < 256) s_sum[tid] += s_sum[tid + 256]; __syncthreads();
    if (tid < 128) s_sum[tid] += s_sum[tid + 128]; __syncthreads();
    if (tid <  64) s_sum[tid] += s_sum[tid + 64];  __syncthreads();
    if (tid <  32) warp_reduce(s_sum, tid); 
    
    if (tid ==  0) 
    {
        g_sum_o[0] = s_sum[0]; 
    }
}


/*----------------------------------------------------------------------------80
    If the returned value > 0, the neighbor list will be updated.
------------------------------------------------------------------------------*/

static int check_atom_distance(Parameters *para, Atom *atom)
{
    int N = para->N;
    int M = (N - 1) / 1024 + 1;
         
    real d2 = HALF * HALF; // to be generalized to use input
   
    int *s1;
    cudaMalloc((void**)&s1, sizeof(int) * M);
         
    int *s2;
    cudaMalloc((void**)&s2, sizeof(int));
         
    check_atom_distance_1<<<M, 1024>>>
    (
        N, d2, atom->x0, atom->y0, atom->z0, 
        atom->x, atom->y, atom->z, s1
    );
    check_atom_distance_2<<<1, 1024>>>(M, s1, s2);
         
    int *cpu_s2;
    MY_MALLOC(cpu_s2, int, 1);
    cudaMemcpy(cpu_s2, s2, sizeof(int), cudaMemcpyDeviceToHost);
        
    cudaFree(s1);
    cudaFree(s2);

    int update = cpu_s2[0];
        
    MY_FREE(cpu_s2);

    return update;
}




// pull the atoms back to the box 
// only do this after updating the neighbor list
static __global__ void gpu_apply_pbc
(
    int N, int pbc_x, int pbc_y, int pbc_z, 
    real *box_length, real *x, real *y, real *z
)
{
    int n = blockIdx.x * blockDim.x + threadIdx.x;
    real lx = box_length[0];
    real ly = box_length[1];
    real lz = box_length[2];

    if (n < N)
    {
        if (pbc_x == 1)
        {
            if      (x[n] < 0)  {x[n] += lx;} 
            else if (x[n] > lx) {x[n] -= lx;}
        }
        if (pbc_y == 1)
        {
            if      (y[n] < 0)  {y[n] += ly;} 
            else if (y[n] > ly) {y[n] -= ly;}
        }
        if (pbc_z == 1)
        {
            if      (z[n] < 0)  {z[n] += lz;} 
            else if (z[n] > lz) {z[n] -= lz;}
        }
   }
}




// update the reference positions:
static __global__ void gpu_update_xyz0
(int N, real *x, real *y, real *z, real *x0, real *y0, real *z0)
{
    int n = blockIdx.x * blockDim.x + threadIdx.x;   
    if (n < N)
    {
        x0[n] = x[n];
        y0[n] = y[n];
        z0[n] = z[n];
    }  
}




// check the bound of the neighbor list
static void check_bound(Parameters *para, Atom *atom)
{
    int N = para->N;
    int *NN = atom->NN;
    int *cpu_NN;
    MY_MALLOC(cpu_NN, int, N);
    CHECK(cudaMemcpy(cpu_NN, NN, sizeof(int)*N, cudaMemcpyDeviceToHost));
    int flag = 0;
    for (int n = 0; n < N; ++n)
    {
        if (cpu_NN[n] > para->neighbor.MN)
        {
            printf
            (
                "Error: NN[%d] = %d > %d\n", n, cpu_NN[n], 
                para->neighbor.MN
            );
            flag = 1;
        }
    }
    if (flag == 1)
    {
        exit(1); // The user should make sure that MN is large enough
    }
    MY_FREE(cpu_NN);
}




void find_neighbor(Parameters *para, Atom *atom)
{

#ifdef DEBUG
    
    // always use the ON2 method when debugging, because it's deterministic
    find_neighbor_ON2(para, atom);

#else

    real rc = para->neighbor.rc;
    real *box = atom->box_length;
    real *cpu_box;
    MY_MALLOC(cpu_box, real, 3);

    // the box might have been updated
    int m = sizeof(real) * DIM;
    CHECK(cudaMemcpy(cpu_box, box, m, cudaMemcpyDeviceToHost));

    // determine the number of cells and the method
    int cell_n_x = 0;
    int cell_n_y = 0;
    int cell_n_z = 0;
    int use_ON2 = 0;

    if (para->pbc_x) 
    {
        cell_n_x = floor(cpu_box[0] / rc);
        if (cell_n_x < 3) {use_ON2 = 1;}
    }
    else {cell_n_x = 1;}

    if (para->pbc_y) 
    {
        cell_n_y = floor(cpu_box[1] / rc);
        if (cell_n_y < 3) {use_ON2 = 1;}
    }
    else {cell_n_y = 1;}

    if (para->pbc_z) 
    {
        cell_n_z = floor(cpu_box[2] / rc);
        if (cell_n_z < 3) {use_ON2 = 1;}
    }
    else {cell_n_z = 1;}

    MY_FREE(cpu_box);

    if (cell_n_x * cell_n_y * cell_n_z < NUM_OF_CELLS) {use_ON2 = 1;}

    // update the neighbor list using an appropriate method
    // the ON1 method is not applicable whenener there is less than 3 bins
    // in any direction (with pbc) and is also not efficient when the number
    // of bins is small
    if (use_ON2)
    {
        find_neighbor_ON2(para, atom);
    }
    else
    {
        find_neighbor_ON1(para, atom, cell_n_x, cell_n_y, cell_n_z);
    }

#endif
}




// the driver function to be called outside this file
void find_neighbor(Parameters *para, Atom *atom, int is_first)
{
    if (is_first == 1) // always build in the beginning
    {
        find_neighbor(para, atom); 
        check_bound(para, atom);

        // set up the reference positions
        gpu_update_xyz0<<<(para->N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
        (
            para->N, atom->x, atom->y, atom->z, 
            atom->x0, atom->y0, atom->z0
        );
    } 
    else // only re-build when necessary during the run
    {    
        int update = check_atom_distance(para, atom);

        if (update != 0)
        {
            int N = para->N;

            find_neighbor(para, atom); 
            check_bound(para, atom);
            
            // pull the particles back to the box
            gpu_apply_pbc<<<(N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
            (
                N, para->pbc_x, para->pbc_y, para->pbc_z, atom->box_length, 
                atom->x, atom->y, atom->z
            );
            
            // update the reference positions
            gpu_update_xyz0<<<(N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
            (
                N, atom->x, atom->y, atom->z, 
                atom->x0, atom->y0, atom->z0
            );
        }
    }
} 



