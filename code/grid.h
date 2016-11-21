#include <stdint.h>
#ifndef  __GRID_H__
#define  __GRID_H__

typedef uint8_t grid_elem;

struct Grid {

  Grid(int w, int h) {
    width = w;
    height = h;
    data = new grid_elem[width * height];
  }

  void blank() {
    int num_pixels = width * height;
    for (int i=0; i<num_pixels; i++) {
      data[i] = 0;
    }
  }

  int width;
  int height;
  grid_elem* data;
};


#endif