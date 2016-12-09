#include <string>
#include <algorithm>
#include <math.h>
#include <stdio.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#include "34-2.h"
#include "util.h"
#include "plugins.h"

////////////////////////////////////////////////////////////////////////////////////////
// Putting all the cuda kernels here
///////////////////////////////////////////////////////////////////////////////////////

struct global_constants {
  int grid_width;
  int grid_height;
  grid_elem* curr_grid;
  grid_elem* next_grid;
};

// Global variable that is in scope, but read-only, for all cuda
// kernels.  The __constant__ modifier designates this variable will
// be stored in special "constant" memory on the GPU. (we didn't talk
// about this type of memory in class, but constant memory is a fast
// place to put read-only variables).
__constant__ global_constants const_params;





// kernelClearGrid --  (CUDA device code)
//
// Clear the grid, setting all cells to 0
__global__ void kernel_clear_grid() {

  // cells at border are not modified
  int image_x = blockIdx.x * blockDim.x + threadIdx.x + 1;
  int image_y = blockIdx.y * blockDim.y + threadIdx.y + 1;

  int width = const_params.grid_width;
  int height = const_params.grid_width;

  // cells at border are not modified
  if (image_x >= width - 1 || image_y >= height - 1)
      return;

  int offset = image_y*width + image_x;

  // write to global memory
  const_params.curr_grid[offset] = 0;
}


// kernel_single_iteration (CUDA device code)
//
// compute a single iteration on the grid, putting the results in next_grid
__global__ void kernel_single_iteration(grid_elem* curr_grid, grid_elem* next_grid) {
  // cells at border are not modified
  int image_x = blockIdx.x * blockDim.x + threadIdx.x + 1;
  int image_y = blockIdx.y * blockDim.y + threadIdx.y + 1;

  int width = const_params.grid_width;
  int height = const_params.grid_width;
  // index in the grid of this thread
  int grid_index = image_y*width + image_x;

  // cells at border are not modified
  if (image_x >= width - 1 || image_y >= height - 1)
      return;
    printf("inside kernel_single_iteration!\n");

  uint8_t live_neighbors = 0;

  // compute the number of live_neighbors
  // neighbors = index of {up, up-right, right, down, down-left, left}
  // int neighbors[] = {grid_index - width, grid_index - width + 1, grid_index + 1,
  //                    grid_index + width, grid_index + width - 1, grid_index - 1};

  //depending on which row the cell is at it has 2 different neighbors?
  int neighbor_offset = 2 * (image_y % 2) - 1;
  int neighbors_indices[] = {grid_index - 1, grid_index + 1, grid_index - width, grid_index + width, 
                     grid_index - width + neighbor_offset, grid_index + width + neighbor_offset};
  grid_elem neighbors[6];
  for (int i = 0; i < 6; i++) {
    neighbors[i] = curr_grid[neighbors_indices[i]];
  }

  //grid_elem curr_value = const_params.curr_grid[grid_index];
  grid_elem curr_value = curr_grid[grid_index];
  // values for the next iteration
  printf("hello from cuda automata!\n");
  grid_elem next_value = update_cell(curr_value, neighbors);
  //grid_elem next_value = 0;
  //const_params.next_grid[grid_index] = next_value;
  next_grid[grid_index] = next_value;

}


Automaton34_2::Automaton34_2() {
  num_iters = 0;
  grid = NULL;
  cuda_device_grid_curr = NULL;
  cuda_device_grid_next = NULL;
}

Automaton34_2::~Automaton34_2() {
  if (grid) {
    delete grid->data;
    delete grid;
  }
  if (cuda_device_grid_curr) {
    cudaFree(cuda_device_grid_curr);
    cudaFree(cuda_device_grid_next);
  }
}

Grid*
Automaton34_2::get_grid() {

  // need to copy contents of the final grid from device memory
  // before we expose it to the caller

  //printf("Copying grid data from device\n");

  cudaMemcpy(grid->data,
             cuda_device_grid_curr,
             sizeof(grid_elem) * grid->width * grid->height,
             cudaMemcpyDeviceToHost);

  return grid;
}

void
Automaton34_2::setup(int num_of_iters) {

  int deviceCount = 0;
  bool isFastGPU = false;
  std::string name;
  cudaError_t err = cudaGetDeviceCount(&deviceCount);

  printf("Number of iterations: %d\n", num_of_iters);
  num_iters = num_of_iters;

  printf("---------------------------------------------------------\n");
  printf("Initializing CUDA for CudaRenderer\n");
  printf("Found %d CUDA devices\n", deviceCount);



  // By this time the scene should be loaded.  Now copy all the key
  // data structures into device memory so they are accessible to
  // CUDA kernels

  cudaMalloc(&cuda_device_grid_curr, sizeof(grid_elem) * grid->width * grid->height);
  cudaMalloc(&cuda_device_grid_next, sizeof(grid_elem) * grid->width * grid->height);

  cudaMemcpy(cuda_device_grid_curr, grid->data,
              sizeof(grid_elem) * grid->width * grid->height, cudaMemcpyHostToDevice);
  cudaMemset(cuda_device_grid_next, 0, sizeof(grid_elem) * grid->width * grid->height);

  // Initialize parameters in constant memory.
  global_constants params;
  params.grid_height = grid->height;
  params.grid_width = grid->width;
  params.curr_grid = cuda_device_grid_curr;
  params.next_grid = cuda_device_grid_next;

  cudaMemcpyToSymbol(const_params, &params, sizeof(global_constants));
}


// create the initial grid using the input file
void
Automaton34_2::create_grid(char *filename) {

  FILE *input = NULL;
  int width, height;
  grid_elem *data;

  input = fopen(filename, "r");
  if (!input) {
    printf("Unable to open file: %s\n", filename);
    printf("\nTerminating program\n");
    exit(1);
  }

  // copy in width and height from file
  if (fscanf(input, "%d %d\n", &width, &height) != 2) {
    fclose(input);
    printf("Invalid input\n");
    printf("\nTerminating program\n");
    exit(1);
  }

  printf("Width: %d\nHeight: %d\n", width, height);

  // increase grid size to account for border cells
  width += 2;
  height += 2;
  data = new grid_elem [width*height];

  // insert data from file into grid
  for (int y = 1; y < height - 1; y++) {
    for (int x = 1; x < width - 1; x++) {
      int temp;
      if (fscanf(input, "%d", &temp) != 1) {
        fclose(input);
        printf("Invalid input\n");
        printf("\nTerminating program\n");
        exit(1);
      }

      data[width*y + x] = (grid_elem)temp;
    }
  }

  fclose(input);

  grid = new Grid(width, height);
  grid->data = data;
}

#define THREAD_DIMX 32
#define THREAD_DIMY 32

//single update
void 
Automaton34_2::update_cells() {
  int width_cells = grid->width - 2;
  int height_cells = grid->height - 2;

  // block/grid size for the pixel kernal
  dim3 cell_block_dim(THREAD_DIMX, THREAD_DIMY);
  dim3 cell_grid_dim((width_cells + cell_block_dim.x - 1) / cell_block_dim.x,
              (height_cells + cell_block_dim.y - 1) / cell_block_dim.y);
  kernel_single_iteration<<<cell_grid_dim, cell_block_dim>>>( cuda_device_grid_curr, cuda_device_grid_next);
    cudaThreadSynchronize();
  grid_elem* temp = cuda_device_grid_curr;
  cuda_device_grid_curr = cuda_device_grid_next;
  cuda_device_grid_next = temp;
}

void
Automaton34_2::run_automaton() {

  // number of threads needed in the x and y directions
  // note that this is less than the width/height due to the border of unmodified cells
  int width_cells = grid->width - 2;
  int height_cells = grid->height - 2;
  printf("run_automaton!\n");

  // block/grid size for the pixel kernal
  dim3 cell_block_dim(THREAD_DIMX, THREAD_DIMY);
  dim3 cell_grid_dim((width_cells + cell_block_dim.x - 1) / cell_block_dim.x,
              (height_cells + cell_block_dim.y - 1) / cell_block_dim.y);

  for (int iter = 0; iter < num_iters; iter++) {
    printf("calling kernel single iteration\n");
    kernel_single_iteration<<<cell_grid_dim, cell_block_dim>>>( cuda_device_grid_curr, cuda_device_grid_next);
    cudaThreadSynchronize();
    printf("finished calling kernel single iteration\n");
    //cudaMemcpy(cuda_device_grid_curr, cuda_device_grid_next,
      //sizeof(grid_elem) * grid->width * grid->height, cudaMemcpyDeviceToDevice);
    grid_elem* temp = cuda_device_grid_curr;
    cuda_device_grid_curr = cuda_device_grid_next;
    cuda_device_grid_next = temp;
  }
}
