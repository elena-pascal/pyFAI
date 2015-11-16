# coding: utf-8
#
#    Project: Azimuthal integration
#             https://github.com/pyFAI/pyFAI
#
#    Copyright (C) 2015 European Synchrotron Radiation Facility, Grenoble, France
#
#    Principal author:       Jérôme Kieffer (Jerome.Kieffer@ESRF.eu)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.


from __future__ import absolute_import, print_function, division

__author__ = "Jerome Kieffer"
__contact__ = "Jerome.Kieffer@ESRF.eu"
__license__ = "MIT"
__copyright__ = "European Synchrotron Radiation Facility, Grenoble, France"
__date__ = "16/11/2015"
__status__ = "development"
__docformat__ = 'restructuredtext'
__doc__ = """

Module with GUI for diffraction mapping experiments 


"""


class DiffMap(object):
    """
    Basic class for diffraction mapping experiment using pyFAI
    """
    def __init__(self, npt_fast=1, npt_slow=1, npt_rad=1000, npt_azim=None):
        """Constructor of the class DiffMap for diffraction mapping

        @param npt_fast: number of translations
        @param npt_slow: number of translations
        @param npt_rad: number of points in diffraction pattern (radial dimension)
        @param npt_azim:  number of points in diffraction pattern (azimuthal dimension)
        """
        self.npt_fast = npt_fast
        self.npt_slow = npt_slow
        self.npt_rad = npt_rad
        self.offset = 0
        self.poni = None
        self.ai = None
        self.dark = None
        self.flat = None
        self.mask = None
        self.I0 = None
        self.hdf5 = None
        self.hdf5path = "diff_tomo/data/sinogram"
        self.group = None
        self.dataset = None
        self.inputfiles = []
        self.timing = []
        self.use_gpu = False
        self.unit = to_unit("2th_deg")
        self.stats = False
        self._idx = -1

    def __repr__(self):
        return "Diffraction Tomography with r=%s t: %s, d:%s" % \
            (self.npt_slow, self.npt_fast, self.npt_rad)

    def parse(self):
        """
        parse options from command line
        """
        description = """Azimuthal integration for diffraction tomography.

Diffraction tomography is an experiment where 2D diffraction patterns are recorded
while performing a 2D scan, one (the slowest) in rotation around the sample center
and the other (the fastest) along a translation through the sample.
Diff_tomo is a script (based on pyFAI and h5py) which allows the reduction of this
4D dataset into a 3D dataset containing the rotations angle (hundreds), the translation step (hundreds)
and the many diffraction angles (thousands). The resulting dataset can be opened using PyMca roitool
where the 1d dataset has to be selected as last dimension. This file is not (yet) NeXus compliant.

This tool can be used for mapping experiments if one considers the slow scan direction as the rotation.
        """
        epilog = """If the number of files is too large, use double quotes "*.edf" """
        usage = """diff_tomo [options] -p ponifile imagefiles*
If the number of files is too large, use double quotes like "*.edf" """
        version = "diff_tomo from pyFAI  version %s: %s" % (PyFAI_VERSION, PyFAI_DATE)
        parser = ArgumentParser(usage=usage, description=description, epilog=epilog)
        parser.add_argument("-V", "--version", action='version', version=version)
        parser.add_argument("args", metavar="FILE", help="List of files to calibrate", nargs='+')
        parser.add_argument("-o", "--output", dest="outfile",
                            help="HDF5 File where processed sinogram was saved, by default diff_tomo.h5",
                            metavar="FILE", default="diff_tomo.h5")
        parser.add_argument("-v", "--verbose",
                            action="store_true", dest="verbose", default=False,
                            help="switch to verbose/debug mode, defaut: quiet")
        parser.add_argument("-P", "--prefix", dest="prefix",
                            help="Prefix or common base for all files",
                            metavar="FILE", default="", type=str)
        parser.add_argument("-e", "--extension", dest="extension",
                            help="Process all files with this extension",
                            default="")
        parser.add_argument("-t", "--nTrans", dest="nTrans",
                            help="number of points in translation. Mandatory", default=None)
        parser.add_argument("-r", "--nRot", dest="nRot",
                            help="number of points in rotation. Mandatory", default=None)
        parser.add_argument("-c", "--nDiff", dest="nDiff",
                            help="number of points in diffraction powder pattern, Mandatory",
                            default=None)
        parser.add_argument("-d", "--dark", dest="dark", metavar="FILE",
                            help="list of dark images to average and subtract",
                            default=None)
        parser.add_argument("-f", "--flat", dest="flat", metavar="FILE",
                            help="list of flat images to average and divide",
                            default=None)
        parser.add_argument("-m", "--mask", dest="mask", metavar="FILE",
                            help="file containing the mask, no mask by default", default=None)
        parser.add_argument("-p", "--poni", dest="poni", metavar="FILE",
                            help="file containing the diffraction parameter (poni-file), Mandatory",
                            default=None)
        parser.add_argument("-O", "--offset", dest="offset",
                            help="do not process the first files", default=None)
        parser.add_argument("-g", "--gpu", dest="gpu", action="store_true",
                            help="process using OpenCL on GPU ", default=False)
        parser.add_argument("-S", "--stats", dest="stats", action="store_true",
                            help="show statistics at the end", default=False)

        options = parser.parse_args()
        args = options.args

        if options.verbose:
            logger.setLevel(logging.DEBUG)
        self.hdf5 = options.outfile
        if options.dark:
            dark_files = [os.path.abspath(urlparse(f).path)
                          for f in options.dark.split(",")
                          if os.path.isfile(urlparse(f).path)]
            if dark_files:
                self.dark = dark_files
            else:
                raise RuntimeError("No such dark files")

        if options.flat:
            flat_files = [os.path.abspath(urlparse(f).path)
                          for f in options.flat.split(",")
                          if os.path.isfile(urlparse(f).path)]
            if flat_files:
                self.flat = flat_files
            else:
                raise RuntimeError("No such flat files")

        self.use_gpu = options.gpu
        self.inputfiles = []
        for fn in args:
            f = urlparse(fn).path
            if os.path.isfile(f) and f.endswith(options.extension):
                self.inputfiles.append(os.path.abspath(f))
            elif os.path.isdir(f):
                self.inputfiles += [os.path.abspath(os.path.join(f, g)) for g in os.listdir(f) if g.endswith(options.extension) and g.startswith(options.prefix)]
            else:
                self.inputfiles += [os.path.abspath(f) for f in glob.glob(f)]
        self.inputfiles.sort(key=to_tuple)
        if not self.inputfiles:
            raise RuntimeError("No input files to process, try --help")
        if options.mask:
            mask = urlparse(options.mask).path
            if os.path.isfile(mask):
                logger.info("Reading Mask file from: %s" % mask)
                self.mask = os.path.abspath(mask)
            else:
                logger.warning("No such mask file %s" % mask)
        if options.poni:
            if os.path.isfile(options.poni):
                logger.info("Reading PONI file from: %s" % options.poni)
                self.poni = options.poni
            else:
                logger.warning("No such poni file %s" % options.poni)
        if options.nTrans is not None:
            self.npt_fast = int(options.nTrans)
        if options.nRot is not None:
            self.npt_slow = int(options.nRot)
        if options.npt_rad is not None:
            self.npt_rad = int(options.npt_rad)
        if options.offset is not None:
            self.offset = int(options.offset)
        else:
            self.offset = 0
        self.stats = options.stats

    def makeHDF5(self, rewrite=False):
        """
        Create the HDF5 structure if needed ...
        """
        print("Initialization of HDF5 file")
        if os.path.exists(self.hdf5) and rewrite:
            os.unlink(self.hdf5)

        spath = self.hdf5path.split("/")
        assert len(spath) > 2
        nxs = Nexus(self.hdf5, mode="w")
        entry = nxs.new_entry(entry=spath[0], program_name="pyFAI", title="diff_tomo")
        grp = entry
        for subgrp in spath[1:-2]:
            grp = nxs.new_class(grp, name=subgrp, class_type="NXcollection")

        processgrp = nxs.new_class(grp, "pyFAI", class_type="NXprocess")
        processgrp["program"] = numpy.array([numpy.str_(i) for i in sys.argv])
        processgrp["version"] = numpy.str_(PyFAI_VERSION)
        processgrp["date"] = numpy.str_(get_isotime())
        if self.mask:
            processgrp["maskfile"] = numpy.str_(self.mask)
        if self.flat:
            processgrp["flatfiles"] = numpy.array([numpy.str_(i) for i in self.flat])
        if self.dark:
            processgrp["darkfiles"] = numpy.array([numpy.str_(i) for i in self.dark])
        processgrp["inputfiles"] = numpy.array([numpy.str_(i) for i in self.inputfiles])
        processgrp["PONIfile"] = numpy.str_(self.poni)

        processgrp["dim0"] = self.npt_slow
        processgrp["dim0"].attrs["axis"] = "Rotation"
        processgrp["dim1"] = self.npt_fast
        processgrp["dim1"].attrs["axis"] = "Translation"
        processgrp["dim2"] = self.npt_rad
        processgrp["dim2"].attrs["axis"] = "Diffraction"
        for k, v in self.ai.getPyFAI().items():
            if "__len__" in dir(v):
                processgrp[k] = numpy.str_(v)
            elif v:
                processgrp[k] = v

        self.group = nxs.new_class(grp, name=spath[-2], class_type="NXdata")

        if posixpath.basename(self.hdf5path) in self.group:
            self.dataset = self.group[posixpath.basename(self.hdf5path)]
        else:
            self.dataset = self.group.create_dataset(
                name=posixpath.basename(self.hdf5path),
                shape=(self.npt_slow, self.npt_fast, self.npt_rad),
                dtype="float32",
                chunks=(1, self.npt_fast, self.npt_rad),
                maxshape=(None, None, self.npt_rad))
            self.dataset.attrs["signal"] = "1"
            self.dataset.attrs["interpretation"] = "spectrum"
            self.dataset.attrs["axes"] = str(self.unit).split("_")[0]
            self.dataset.attrs["creator"] = "pyFAI"
            self.dataset.attrs["long_name"] = "Diffraction imaging experiment"
        self.nxs = nxs

    def setup_ai(self):
        print("Setup of Azimuthal integrator ...")
        if self.poni:
            self.ai = pyFAI.load(self.poni)
        else:
            logger.error(("Unable to setup Azimuthal integrator:"
                          " no poni file provided"))
            raise RuntimeError("You must provide poni a file")
        if self.dark:
            self.ai.set_darkfiles(self.dark)
        if self.flat:
            self.ai.set_flatfiles(self.flat)
        if self.mask is not None:
            self.ai.detector.set_maskfile(self.mask)

    def init_ai(self):
        if not self.ai:
            self.setup_ai()
        if not self.group:
            self.makeHDF5(rewrite=False)
        if self.ai.detector.shape:
            data = numpy.empty(self.ai.detector.shape, dtype=numpy.float32)
            meth = "csr_ocl_gpu" if self.use_gpu else "csr"
            print("Initialization of the Azimuthal Integrator using method %s" % meth)
            # enforce initialization of azimuthal integrator
            tth, I = self.ai.integrate1d(data, self.npt_rad,
                                         method=meth, unit=self.unit)
            if self.dataset is None:
                self.makeHDF5()
            space, unit = str(self.unit).split("_")
            if space not in self.group:
                self.group[space] = tth
                self.group[space].attrs["axes"] = 3
                self.group[space].attrs["unit"] = unit
                self.group[space].attrs["long_name"] = self.unit.label
                self.group[space].attrs["interpretation"] = "scalar"
            if self.use_gpu:
                self.ai._ocl_csr_integr.output_dummy = 0.0
            else:
                self.ai._csr_integrator.output_dummy = 0.0

    def show_stats(self):
        if not self.stats:
            return
        try:
            import matplotlib.pyplot as plt
        except ImportError:
            logger.error("Unable to start matplotlib for display")
            return

        plt.hist(self.timing, 500, facecolor='green', alpha=0.75)
        plt.xlabel('Execution time in sec')
        plt.title("Execution time")
        plt.grid(True)
        plt.show()

    def get_pos(self, filename, idx=None):
        """
        Calculate the position in the sinogram of the file according
        to it's number
        
        @param filename: name of current frame
        @param idx: index of current frame
        @return: namedtuple: index, rot, trans
        """
        #         n = int(filename.split(".")[0].split("_")[-1]) - (self.offset or 0)
        if idx is None:
            n = self.inputfiles.index(filename) - self.offset
        else:
            n = idx - self.offset
        return Position(n, n // self.npt_fast, n % self.npt_fast)

    def process_one_file(self, filename):
        """
        @param filename: name of the input filename
        @param idx: index of file
        """
        if self.ai is None:
            self.setup_ai()
        if self.dataset is None:
            self.makeHDF5()

        t = time.time()
        self._idx += 1
        pos = self.get_pos(filename, self._idx)
        shape = self.dataset.shape
        if pos.rot + 1 > shape[0]:
            self.dataset.resize((pos.rot + 1, shape[1], shape[2]))
        elif pos.index < 0 or pos.rot < 0 or pos.trans < 0:
            return
        fimg = fabio.open(filename)

        meth = "csr_ocl_gpu" if self.use_gpu else "csr"
        tth, I = self.ai.integrate1d(fimg.data, self.npt_rad, safe=False,
                                     method=meth, unit=self.unit)
        self.dataset[pos.rot, pos.trans, :] = I

        if fimg.nframes > 1:
            print("Case of multiframe images")
            for i in range(fimg.nframes - 1):
                fimg = fimg.next()
                data = fimg.data
                self._idx += 1
                pos = self.get_pos(filename, self._idx)
                if pos.rot + 1 > shape[0]:
                    self.dataset.resize((pos.rot + 1, shape[1], shape[2]))
                tth, I = self.ai.integrate1d(data, self.npt_rad, safe=False,
                                             method=meth, unit=self.unit)
                self.dataset[pos.rot, pos.trans, :] = I

        t -= time.time()
        print("Processing %30s took %6.1fms" %
              (os.path.basename(filename), -1000 * t))
        self.timing.append(-t)

    def process(self):
        if self.dataset is None:
            self.makeHDF5()
        self.init_ai()
        t0 = time.time()
        self._idx = -1
        for f in self.inputfiles:
            self.process_one_file(f)
        self.nxs.close
        tot = time.time() - t0
        cnt = self._idx + 1
        print(("Execution time for %i frames: %.3fs;"
               " Average execution time: %.1fms") %
              (cnt, tot, 1000. * tot / cnt))
        self.nxs.close()