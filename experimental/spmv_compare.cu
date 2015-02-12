/******************************************************************************
 * Copyright (c) 2011-2015, NVIDIA CORPORATION.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of the NVIDIA CORPORATION nor the
 *       names of its contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL NVIDIA CORPORATION BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 ******************************************************************************/

//---------------------------------------------------------------------
// SpMV comparison tool
//---------------------------------------------------------------------

#include <stdio.h>
#include <map>
#include <vector>
#include <algorithm>
#include <cstdio>
#include <fstream>

#include <cusparse.h>

#include "matrix.h"

#include <cub/util_allocator.cuh>
#include <test/test_util.h>

using namespace cub;


//---------------------------------------------------------------------
// Globals, constants, and type declarations
//---------------------------------------------------------------------

// Ensure printing of CUDA runtime errors to console
#define CUB_STDERR

bool                    g_verbose = false;  // Whether to display input/output to console
CachingDeviceAllocator  g_allocator(true);  // Caching allocator for device memory


//---------------------------------------------------------------------
// SpMV verification
//---------------------------------------------------------------------

// Compute reference SpMV y = Ax
template <
    typename VertexT,
    typename ValueT,
    typename SizeT>
void SpmvGold(
    CsrMatrix<VertexT, ValueT, SizeT>&      matrix_a,
    ValueT*                                 vector_x,
    ValueT*                                 vector_y)
{
    for (SizeT row = 0; row < matrix_a.num_vertices; ++row)
    {
        vector_y[row] = 0;
        for (
            SizeT column = matrix_a.row_offsets[row];
            column < matrix_a.row_offsets[row + 1];
            ++column)
        {
            vector_y[row] += matrix_a.values[column] * vector_x[matrix_a.column_indices[column]];
        }
    }
}


//---------------------------------------------------------------------
// Test GPU SpMV execution
//---------------------------------------------------------------------

/**
 * Run cuSparse SpMV (specialized for fp32)
 */
template <
    typename VertexT,
    typename SizeT>
float CusparseSpmv(
    int                 num_rows,
    int                 num_cols,
    int                 num_nonzeros,
    float*              d_matrix_values,
    SizeT*              d_matrix_row_offsets,
    VertexT*            d_matrix_column_indices,
    float*              d_vector_x,
    float*              d_vector_y,
    int                 timing_iterations,
    cusparseHandle_t    cusparse)
{
    cusparseMatDescr_t desc;
    cusparseCreateMatDescr(&desc);
    float alpha             = 1.0;
    float beta              = 0.0;

    float elapsed_millis    = 0.0;
    GpuTimer gpu_timer;

    for(int it = 0; it < timing_iterations; ++it)
    {
        gpu_timer.Start();

        cusparseStatus_t status = cusparseScsrmv(
            cusparse,
            CUSPARSE_OPERATION_NON_TRANSPOSE,
            num_rows,
            num_cols,
            num_nonzeros,
            &alpha,
            desc,
            d_matrix_values,
            d_matrix_row_offsets,
            d_matrix_column_indices,
            d_vector_x,
            &beta,
            d_vector_y);

        gpu_timer.Stop();
        elapsed_millis += gpu_timer.ElapsedMillis();
    }

    cusparseDestroyMatDescr(desc);
    return elapsed_millis;
}


/**
 * Run cuSparse SpMV (specialized for fp64)
 */
template <
    typename VertexT,
    typename SizeT>
float CusparseSpmv(
    int                 num_rows,
    int                 num_cols,
    int                 num_nonzeros,
    double*             d_matrix_values,
    SizeT*              d_matrix_row_offsets,
    VertexT*            d_matrix_column_indices,
    double*             d_vector_x,
    double*             d_vector_y,
    int                 timing_iterations,
    cusparseHandle_t    cusparse)
{
    cusparseMatDescr_t desc;
    cusparseCreateMatDescr(&desc);
    double alpha            = 1.0;
    double beta             = 0.0;

    float elapsed_millis    = 0.0;
    GpuTimer gpu_timer;

    for(int it = 0; it < timing_iterations; ++it)
    {
        gpu_timer.Start();

        cusparseStatus_t status = cusparseDcsrmv(
            cusparse,
            CUSPARSE_OPERATION_NON_TRANSPOSE,
            num_rows,
            num_cols,
            num_nonzeros,
            &alpha,
            desc,
            d_matrix_values,
            d_matrix_row_offsets,
            d_matrix_column_indices,
            d_vector_x,
            &beta,
            d_vector_y);

        gpu_timer.Stop();
        elapsed_millis += gpu_timer.ElapsedMillis();
    }

    cusparseDestroyMatDescr(desc);
    return elapsed_millis;
}


/**
 * Run a specific histogram implementation
 */
template <
    int         ACTIVE_CHANNELS,
    int         NUM_BINS,
    typename    PixelType>
void RunTest(
    std::vector<std::pair<std::string, double> >&   timings,
    PixelType*                                      d_pixels,
    const int                                       width,
    const int                                       height,
    unsigned int *                                  d_hist,
    unsigned int *                                  h_hist,
    int                                             timing_iterations,
    const char *                                    long_name,
    const char *                                    short_name,
    double (*f)(PixelType*, int, int, unsigned int*, bool))
{
    if (!g_report) printf("%s ", long_name); fflush(stdout);

    // Run single test to verify (and code cache)
    (*f)(d_pixels, width, height, d_hist, !g_report);

    int compare = CompareDeviceResults(h_hist, d_hist, ACTIVE_CHANNELS * NUM_BINS, true, g_verbose);
    if (!g_report) printf("\t%s\n", compare ? "FAIL" : "PASS"); fflush(stdout);

    double elapsed_ms = 0;
    for (int i = 0; i < timing_iterations; i++)
    {
        elapsed_ms += (*f)(d_pixels, width, height, d_hist, false);
    }
    double avg_us = (elapsed_ms / timing_iterations) * 1000;    // average in us
    timings.push_back(std::pair<std::string, double>(short_name, avg_us));

    if (!g_report)
    {
        printf("Avg time %.3f us (%d iterations)\n", avg_us, timing_iterations); fflush(stdout);
    }
    else
    {
        printf("%.3f, ", avg_us); fflush(stdout);
    }

    AssertEquals(0, compare);
}



/**
 * Run tests
 */
template <
    typename VertexT,
    typename ValueT,
    typename SizeT>
void RunTests(
    std::string         &mtx_filename,
    int                 grid2d,
    int                 grid3d,
    int                 wheel,
    int                 timing_iterations,
    float               bandwidth_GBs)
{
    CooMatrix<VertexT, ValueT> coo_matrix;

    if (!mtx_filename.empty())
    {
        // Parse matrix market file
        coo_matrix.InitMarket(mtx_filename);
    }
    else if (grid2d > 0)
    {
        // Generate 2D lattice
        coo_matrix.InitGrid2d(grid2d, false);
    }
    else if (grid3d > 0)
    {
        // Generate 3D lattice
        coo_matrix.InitGrid3d(grid3d, false);
    }
    else if (wheel > 0)
    {
        // Generate wheel graph
        coo_matrix.InitWheel(wheel);
    }
    else
    {
        fprintf(stderr, "No graph type specified.\n");
        exit(1);
    }

    CsrMatrix<VertexT, ValueT, SizeT> csr_matrix;
    csr_matrix.FromCoo(coo_matrix);

    // Display matrix info
    csr_matrix.DisplayHistogram();
}



/**
 * Main
 */
int main(int argc, char **argv)
{
    // Initialize command line
    CommandLineArgs args(argc, argv);
    if (args.CheckCmdLineFlag("help"))
    {
        printf(
            "%s "
            "[--device=<device-id>] "
            "[--v] "
            "[--i=<timing iterations>] "
            "[--fp64] "
            "\n\t"
                "--mtx=<matrix market file> "
            "\n\t"
                "--grid2d=<width>"
            "\n\t"
                "--grid3d=<width>"
            "\n\t"
                "--wheel=<spokes>"
            "\n", argv[0]);
        exit(0);
    }

    bool                fp64;
    std::string         mtx_filename;
    int                 grid2d              = -1;
    int                 grid3d              = -1;
    int                 wheel               = -1;
    int                 timing_iterations   = 100;

    g_verbose = args.CheckCmdLineFlag("v");
    fp64 = args.CheckCmdLineFlag("fp64");
    args.GetCmdLineArgument("i", timing_iterations);
    args.GetCmdLineArgument("mtx", mtx_filename);
    args.GetCmdLineArgument("grid2d", grid2d);
    args.GetCmdLineArgument("grid3d", grid3d);
    args.GetCmdLineArgument("wheel", wheel);

    // Initialize device
    CubDebugExit(args.DeviceInit());

    // Get GPU device bandwidth (GB/s)
    int device_ordinal, bus_width, mem_clock_khz;
    CubDebugExit(cudaGetDevice(&device_ordinal));
    CubDebugExit(cudaDeviceGetAttribute(&bus_width, cudaDevAttrGlobalMemoryBusWidth, device_ordinal));
    CubDebugExit(cudaDeviceGetAttribute(&mem_clock_khz, cudaDevAttrMemoryClockRate, device_ordinal));
    float bandwidth_GBs = float(bus_width) * mem_clock_khz * 2 / 8 / 1000 / 1000;

    // Run test(s)
    if (fp64)
    {
        RunTests<int, double, int>(mtx_filename, grid2d, grid3d, wheel, timing_iterations, bandwidth_GBs);
    }
    else
    {
        RunTests<int, float, int>(mtx_filename, grid2d, grid3d, wheel, timing_iterations, bandwidth_GBs);
    }

    CubDebugExit(cudaDeviceSynchronize());
    printf("\n\n");

    return 0;
}