# coding: utf-8
# cython: embedsignature=True, language_level=3, binding=True
# cython: boundscheck=False, wraparound=False, cdivision=True, initializedcheck=False,
## This is for developping
## cython: profile=True, warn.undeclared=True, warn.unused=True, warn.unused_result=False, warn.unused_arg=True
#
#    Project: Fast Azimuthal Integration
#             https://github.com/silx-kit/pyFAI
#
#    Copyright (C) 2014-2020 European Synchrotron Radiation Facility, Grenoble, France
#
#    Principal author:       Jérôme Kieffer (Jerome.Kieffer@ESRF.eu)
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#  .
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#  .
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

__author__ = "Jérôme Kieffer"
__contact__ = "Jerome.kieffer@esrf.fr"
__date__ = "26/11/2021"
__status__ = "stable"
__license__ = "MIT"


include "regrid_common.pxi"
include "LUT_common.pxi"

import cython
import os
import sys
import logging
logger = logging.getLogger(__name__)
from cython.parallel import prange
from libc.string cimport memset
from cython cimport view
import numpy
cimport numpy
from libc.math cimport fabs, floor, sqrt
from libc.stdlib cimport abs
from libc.stdio cimport printf, fflush, stdout
from .sparse_builder cimport SparseBuilder
from .splitpixel_common import calc_boundaries
from ..utils import crc32
from ..utils.decorators import deprecated


cdef Py_ssize_t NUM_WARNING
if logger.level >= logging.ERROR:
    NUM_WARNING = -1
elif logger.level >= logging.WARNING:
    NUM_WARNING = 10 
elif logger.level >= logging.INFO:
    NUM_WARNING = 100 
else:
    NUM_WARNING = 10000

cdef struct Function:
    float slope
    float intersect


@cython.cdivision(True)
cdef inline float getBin1Nr(floating x0, floating pos0_min, floating delta, floating var) nogil:
    """
    calculate the bin number for any point
    param x0: current position
    param pos0_min: position minimum
    param delta: bin width
    """
    if var:
        if x0 >= 0:
            return (x0 - pos0_min) / delta
        else:
            return (x0 + 2 * pi - pos0_min) / delta   # temporary fix....
    else:
        return (x0 - pos0_min) / delta


@cython.cdivision(True)
cdef inline floating integrate(floating A0, floating B0, Function AB) nogil:
    """
    integrates the line defined by AB, from A0 to B0
    param A0: first limit
    param B0: second limit
    param AB: struct with the slope and point of intersection of the line
    """
    if A0 == B0:
        return 0.0
    else:
        return AB.slope * (B0 * B0 - A0 * A0) * 0.5 + AB.intersect * (B0 - A0)


class HistoLUT1dFullSplit(LutIntegrator):
    """
    Now uses LUT representation for the integration
    """
    @cython.boundscheck(False)
    def __init__(self,
                 numpy.ndarray pos not None,
                 int bins=100,
                 pos0_range=None,
                 pos1_range=None,
                 mask=None,
                 mask_checksum=None,
                 allow_pos0_neg=False,
                 unit="undefined",
                 empty=None):
        """
        :param pos: 3D or 4D array with the coordinates of each pixel point
        :param bins: number of output bins, 100 by default
        :param pos0_range: minimum and maximum  of the 2th range
        :param pos1_range: minimum and maximum  of the chi range
        :param mask: array (of int8) with masked pixels with 1 (0=not masked)
        :param allow_pos0_neg: enforce the q<0 is usually not possible
        :param unit: can be 2th_deg or r_nm^-1 ...
        """
        if pos.ndim > 3:  # create a view
            pos = pos.reshape((-1, 4, 2))
        assert pos.shape[1] == 4, "pos.shape[1] == 4"
        assert pos.shape[2] == 2, "pos.shape[2] == 2"
        assert pos.ndim == 3, "pos.ndim == 3"
        self.pos = numpy.ascontiguousarray(pos, dtype=position_d)
        self.size = pos.shape[0]
        self.bins = bins
        self.allow_pos0_neg = allow_pos0_neg
        self.unit = unit
        if mask is None:
            self.cmask = None
            self.check_mask = False
            self.mask_checksum = None
        else:
            assert mask.size == self.size, "mask size"
            self.check_mask = True
            self.cmask = numpy.ascontiguousarray(mask.ravel(), dtype=mask_d)
            if mask_checksum:
                self.mask_checksum = mask_checksum
            else:
                self.mask_checksum = crc32(mask)

        #keep this unchanged for validation of the range or not
        self.pos0_range = pos0_range
        self.pos1_range = pos1_range
        cdef:
            position_t pos0_max, pos1_max, pos0_maxin, pos1_maxin
        pos0_min, pos0_maxin, pos1_min, pos1_maxin = calc_boundaries(self.pos, self.cmask, pos0_range, pos1_range)
        if (not allow_pos0_neg):
            pos0_min = max(0.0, pos0_min)
            pos0_maxin = max(pos0_maxin, 0.0)
        self.pos0_min = pos0_min
        self.pos1_min = pos1_min
        self.pos0_max = pos0_max = calc_upper_bound(pos0_maxin)
        self.pos1_max = pos1_max = calc_upper_bound(pos1_maxin)

        self.delta = (self.pos0_max - self.pos0_min) / (<position_t> (bins))
        self.bin_centers = numpy.linspace(pos0_min + 0.5 * self.delta, 
                                          pos0_max - 0.5 * self.delta, 
                                          self.bins)
        

        lut = self.calc_lut()
        #Call the constructor of the parent class
        super().__init__(lut, pos.shape[0], empty or 0.0)
        self.lut_checksum = crc32(self.lut)
        self.lut_nbytes = sum([i.nbytes for i in self.lut])

    def calc_lut(self):
        cdef:
            position_t[:,:, ::1] cpos = numpy.ascontiguousarray(self.pos, dtype=position_d)
            mask_t[:] cmask = None
            position_t pos0_min, pos1_min, pos1_max
            position_t max0, min0
            position_t delta = self.delta, areaPixel = 0, areaPixel2 = 0
            position_t A0 = 0, B0 = 0, C0 = 0, D0 = 0, A1 = 0, B1 = 0, C1 = 0, D1 = 0
            position_t A_lim = 0, B_lim = 0, C_lim = 0, D_lim = 0
            position_t partialArea = 0, oneOverPixelArea
            Function AB, BC, CD, DA
            Py_ssize_t bins=self.bins, idx = 0, bin = 0, bin0 = 0, bin0_max = 0, bin0_min = 0, size = self.size
            bint check_pos1, check_mask = self.cmask is not None
            SparseBuilder builder = SparseBuilder(bins, block_size=32, heap_size=size)
            
        if check_mask:
            cmask = self.cmask
        pos0_min = self.pos0_min
        pos1_min = self.pos1_min
        pos1_max = self.pos1_max  
        check_pos1 = self.pos1_range is not None
        
        with nogil:
            for idx in range(size):
                if (check_mask) and (cmask[idx]):
                    continue

                A0 = get_bin_number(cpos[idx, 0, 0], pos0_min, delta)
                A1 = cpos[idx, 0, 1]
                B0 = get_bin_number(cpos[idx, 1, 0], pos0_min, delta)
                B1 = cpos[idx, 1, 1]
                C0 = get_bin_number(cpos[idx, 2, 0], pos0_min, delta)
                C1 = cpos[idx, 2, 1]
                D0 = get_bin_number(cpos[idx, 3, 0], pos0_min, delta)
                D1 = cpos[idx, 3, 1]

                min0 = min(A0, B0, C0, D0)
                max0 = max(A0, B0, C0, D0)

                if (max0 < 0) or (min0 >= bins):
                    continue
                if check_pos1:
                    if (max(A1, B1, C1, D1) < pos1_min) or (min(A1, B1, C1, D1) >= pos1_max):
                        continue

                bin0_min = < int > floor(min0)
                bin0_max = < int > floor(max0)

                if bin0_min == bin0_max:
                    # All pixel is within a single bin
                    builder.cinsert(bin0_min, idx, 1.0)

                else:  # else we have pixel spliting.
                    # offseting the min bin of the pixel to be zero to avoid percision problems
                    A0 -= bin0_min
                    B0 -= bin0_min
                    C0 -= bin0_min
                    D0 -= bin0_min

                    AB.slope = (B1 - A1) / (B0 - A0)
                    AB.intersect = A1 - AB.slope * A0
                    BC.slope = (C1 - B1) / (C0 - B0)
                    BC.intersect = B1 - BC.slope * B0
                    CD.slope = (D1 - C1) / (D0 - C0)
                    CD.intersect = C1 - CD.slope * C0
                    DA.slope = (A1 - D1) / (A0 - D0)
                    DA.intersect = D1 - DA.slope * D0

                    areaPixel = fabs(area4(A0, A1, B0, B1, C0, C1, D0, D1))

                    areaPixel2 = integrate(A0, B0, AB)
                    areaPixel2 += integrate(B0, C0, BC)
                    areaPixel2 += integrate(C0, D0, CD)
                    areaPixel2 += integrate(D0, A0, DA)

                    oneOverPixelArea = 1.0 / areaPixel

                    for bin in range(bin0_min, bin0_max + 1):

                        bin0 = bin - bin0_min
                        A_lim = (A0 <= bin0) * (A0 <= (bin0 + 1)) * bin0 + (A0 > bin0) * (A0 <= (bin0 + 1)) * A0 + (A0 > bin0) * (A0 > (bin0 + 1)) * (bin0 + 1)
                        B_lim = (B0 <= bin0) * (B0 <= (bin0 + 1)) * bin0 + (B0 > bin0) * (B0 <= (bin0 + 1)) * B0 + (B0 > bin0) * (B0 > (bin0 + 1)) * (bin0 + 1)
                        C_lim = (C0 <= bin0) * (C0 <= (bin0 + 1)) * bin0 + (C0 > bin0) * (C0 <= (bin0 + 1)) * C0 + (C0 > bin0) * (C0 > (bin0 + 1)) * (bin0 + 1)
                        D_lim = (D0 <= bin0) * (D0 <= (bin0 + 1)) * bin0 + (D0 > bin0) * (D0 <= (bin0 + 1)) * D0 + (D0 > bin0) * (D0 > (bin0 + 1)) * (bin0 + 1)

                        partialArea = integrate(A_lim, B_lim, AB)
                        partialArea += integrate(B_lim, C_lim, BC)
                        partialArea += integrate(C_lim, D_lim, CD)
                        partialArea += integrate(D_lim, A_lim, DA)
                        
                        builder.cinsert(bin, idx, fabs(partialArea) * oneOverPixelArea)
        return builder.to_lut()

    @property
    @deprecated(replacement="bin_centers", since_version="0.16", only_once=True)
    def outPos(self):
        return self.bin_centers

################################################################################
# Bidimensionnal regrouping
################################################################################

class HistoLUT2dFullSplit(LutIntegrator):
    """
    Now uses CSR (Compressed Sparse raw) with main attributes:
    * nnz: number of non zero elements
    * data: coefficient of the matrix in a 1D vector of float32
    * indices: Column index position for the data (same size as
    * indptr: row pointer indicates the start of a given row. len nrow+1

    Nota: nnz = indptr[-1]
    """
    def __init__(self,
                 numpy.ndarray pos not None,
                 bins=(100, 36),
                 pos0_range=None,
                 pos1_range=None,
                 mask=None,
                 mask_checksum=None,
                 allow_pos0_neg=False,
                 unit="undefined",
                 chiDiscAtPi=True):

        """
        :param pos: 3D or 4D array with the coordinates of each pixel point
        :param bins: number of output bins (tth=100, chi=36 by default)
        :param pos0_range: minimum and maximum  of the 2th range
        :param pos1_range: minimum and maximum  of the chi range
        :param mask: array (of int8) with masked pixels with 1 (0=not masked)
        :param allow_pos0_neg: enforce the q<0 is usually not possible
        :param unit: can be 2th_deg or r_nm^-1 ...
        """
        if pos.ndim > 3:  # create a view
            pos = pos.reshape((-1, 4, 2))
        assert pos.shape[1] == 4, "pos.shape[1] == 4"
        assert pos.shape[2] == 2, "pos.shape[2] == 2"
        assert pos.ndim == 3, "pos.ndim == 3"
        self.pos = numpy.ascontiguousarray(pos, dtype=position_d)
        self.size = pos.shape[0]
        self.bins = (max(bins[0], 1), max(bins[1], 1))
        self.unit = unit
        self.lut_size = 0
        self.allow_pos0_neg = allow_pos0_neg
        self.chiDiscAtPi = chiDiscAtPi
        if mask is not None:
            assert mask.size == self.size, "mask size"
            self.check_mask = True
            self.cmask = numpy.ascontiguousarray(mask.ravel(), dtype=mask_d)
            if mask_checksum:
                self.mask_checksum = mask_checksum
            else:
                self.mask_checksum = crc32(mask)
        else:
            self.check_mask = False
            self.mask_checksum = None
            self.mask = None

        #keep this unchanged for validation of the range or not
        self.pos0_range = pos0_range
        self.pos1_range = pos1_range        
        cdef:
            position_t pos0_max, pos1_max, pos0_maxin, pos1_maxin
        pos0_min, pos0_maxin, pos1_min, pos1_maxin = calc_boundaries(self.pos, self.cmask, pos0_range, pos1_range)
        if (not allow_pos0_neg):
            pos0_min = max(0.0, pos0_min)
            pos0_maxin = max(pos0_maxin, 0.0)
        self.pos0_min = pos0_min
        self.pos1_min = pos1_min
        self.pos0_max = pos0_max = calc_upper_bound(pos0_maxin)
        self.pos1_max = pos1_max = calc_upper_bound(pos1_maxin)

        self.delta0 = (pos0_max - pos0_min) / (<position_t> (bins[0]))
        self.delta1 = (pos1_max - pos1_min) / (<position_t> (bins[1]))
        self.bin_centers0 = numpy.linspace(pos0_min + 0.5 * self.delta0, 
                                           pos0_max - 0.5 * self.delta0, 
                                           self.bins[0])
        self.bin_centers1 = numpy.linspace(pos1_min + 0.5 * self.delta1, 
                                           pos1_max - 0.5 * self.delta1, 
                                           self.bins[1])

        lut = self.calc_lut()

        self.lut_checksum = crc32(numpy.asarray(lut))
        
    def calc_lut(self):
        cdef:
            Py_ssize_t bins0=self.bins[0], bins1=self.bins[1], size = self.size
            position_t[:, :, ::1] cpos = numpy.ascontiguousarray(self.pos, dtype=position_d)
            position_t[:, ::1] v8 = numpy.empty((4,2), dtype=position_d)
            mask_t[:] cmask = self.cmask
            bint check_mask = self.mask is not None, chiDiscAtPi = self.chiDiscAtPi
            position_t min0 = 0, max0 = 0, min1 = 0, max1 = 0, inv_area = 0
            position_t pos0_min = 0, pos0_max = 0, pos1_min = 0, pos1_max = 0, pos0_maxin = 0, pos1_maxin = 0
            position_t a0 = 0, a1 = 0, b0 = 0, b1 = 0, c0 = 0, c1 = 0, d0 = 0, d1 = 0
            position_t area
            position_t delta0=self.delta0, delta1=self.delta1
            Py_ssize_t i = 0, j = 0, idx = 0
            Py_ssize_t ioffset0, ioffset1, w0, w1, bw0=15, bw1=15, nwarn=NUM_WARNING
            buffer_t[::1] linbuffer = numpy.empty(256, dtype=buffer_d)
            buffer_t[:, ::1] buffer = numpy.asarray(linbuffer[:(bw0+1)*(bw1+1)]).reshape((bw0+1,bw1+1))
            position_t foffset0, foffset1, sum_area, loc_area
            SparseBuilder builder = SparseBuilder(bins1*bins0, block_size=8, heap_size=size)
            
        if check_mask:
            cmask = self.cmask
        pos0_min = self.pos0_min
        pos0_max = self.pos0_max
        pos1_min = self.pos1_min
        pos1_max = self.pos1_max
    
        with nogil:
            for idx in range(size):
    
                if (check_mask) and (cmask[idx]):
                    continue
                    
                # Play with coordinates ...
                v8[:, :] = cpos[idx, :, :]
                area = _recenter(v8, chiDiscAtPi)
                a0 = v8[0, 0]
                a1 = v8[0, 1]
                b0 = v8[1, 0]
                b1 = v8[1, 1]
                c0 = v8[2, 0]
                c1 = v8[2, 1]
                d0 = v8[3, 0]
                d1 = v8[3, 1]
    
                min0 = min(a0, b0, c0, d0)
                max0 = max(a0, b0, c0, d0)
                min1 = min(a1, b1, c1, d1)
                max1 = max(a1, b1, c1, d1)
                
                if (max0 < pos0_min) or (min0 >= pos0_max) or (max1 < pos1_min) or (min1 >= pos1_max):
                        continue
    
                # Swith to bin space.
                a0 = get_bin_number(_clip(a0, pos0_min, pos0_maxin), pos0_min, delta0)
                a1 = get_bin_number(_clip(a1, pos1_min, pos1_maxin), pos1_min, delta1)
                b0 = get_bin_number(_clip(b0, pos0_min, pos0_maxin), pos0_min, delta0)
                b1 = get_bin_number(_clip(b1, pos1_min, pos1_maxin), pos1_min, delta1)
                c0 = get_bin_number(_clip(c0, pos0_min, pos0_maxin), pos0_min, delta0)
                c1 = get_bin_number(_clip(c1, pos1_min, pos1_maxin), pos1_min, delta1)
                d0 = get_bin_number(_clip(d0, pos0_min, pos0_maxin), pos0_min, delta0)
                d1 = get_bin_number(_clip(d1, pos1_min, pos1_maxin), pos1_min, delta1)
                
                # Recalculate here min0, max0, min1, max1 based on the actual area of ABCD and the width/height ratio
                min0 = min(a0, b0, c0, d0)
                max0 = max(a0, b0, c0, d0)
                min1 = min(a1, b1, c1, d1)
                max1 = max(a1, b1, c1, d1)
                foffset0 = floor(min0)
                foffset1 = floor(min1)
                ioffset0 = <Py_ssize_t> foffset0
                ioffset1 = <Py_ssize_t> foffset1
                w0 = <Py_ssize_t>(ceil(max0) - foffset0)
                w1 = <Py_ssize_t>(ceil(max1) - foffset1)
                if (w0>bw0) or (w1>bw1):
                    if (w0+1)*(w1+1)>linbuffer.shape[0]:
                        with gil:
                            linbuffer = numpy.empty((w0+1)*(w1+1), dtype=buffer_d)
                            buffer = numpy.asarray(linbuffer).reshape((w0+1,w1+1))
                            logger.debug("malloc  %s->%s and %s->%s", w0, bw0, w1, bw1) 
                    else:
                        with gil:
                            buffer = numpy.asarray(linbuffer[:(w0+1)*(w1+1)]).reshape((w0+1,w1+1))
                            logger.debug("reshape %s->%s and %s->%s", w0, bw0, w1, bw1)
                    bw0 = w0
                    bw1 = w1
                buffer[:, :] = 0.0
                
                a0 -= foffset0
                a1 -= foffset1
                b0 -= foffset0
                b1 -= foffset1
                c0 -= foffset0
                c1 -= foffset1            
                d0 -= foffset0
                d1 -= foffset1
                
                # ABCD is anti-trigonometric order: order input position accordingly
                _integrate2d(buffer, a0, a1, b0, b1)
                _integrate2d(buffer, b0, b1, c0, c1)
                _integrate2d(buffer, c0, c1, d0, d1)
                _integrate2d(buffer, d0, d1, a0, a1)
    
                area = 0.5 * ((c1 - a1) * (d0 - b0) - (c0 - a0) * (d1 - b1))
                if area == 0.0:
                    continue
                inv_area = 1.0 / area
                sum_area = 0.0
                for i in range(w0):
                    for j in range(w1):
                        loc_area = buffer[i, j]
                        sum_area += loc_area
                        builder.cinsert((ioffset0 + i)*bins1 + ioffset1 + j, idx, loc_area * inv_area)
                        
                if fabs(area - sum_area)*inv_area > 1e-3:
                    nwarn -=1
                    if nwarn>0:
                        with gil:            
                            logger.info(f"Invstigate idx {idx}, area {area} {sum_area}, {numpy.asarray(v8)}, {w0}, {w1}")
        if nwarn<NUM_WARNING:
            logger.info(f"Total number of spurious pixels: {NUM_WARNING - nwarn} / {size} total")
      
        return builder.to_lut()