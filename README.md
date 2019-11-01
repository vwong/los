# Elevation POC

* run `docker-compose up` in one terminal
* add some elevation data to `./data`, I've added:
  - MEL2018_BC_33.flt
  - MEL2018_BC_33.hdr
  - MEL2018_BC_34.flt
  - MEL2018_BC_34.hdr
  - MEL2018_BC_35.flt
  - MEL2018_BC_35.hdr
  - MEL2018_BC_36.flt
  - MEL2018_BC_36.hdr
  - MEL2018_BC_37.flt
  - MEL2018_BC_37.hdr
  - MEL2018_BC_38.flt
  - MEL2018_BC_38.hdr
  - MEL2018_BC_39.flt
  - MEL2018_BC_39.hdr
  - MEL2018_BC_40.flt
  - MEL2018_BC_40.hdr
* run `./bin/seed` in another terminal, this will load the elevation data
* run `./bin/psql` to get yourself access to psql
  * eval `procs.sql` to [re]define the required functions
  * eval the following to perform a LOS calculation

```
  SELECT los_range(
  ST_SetSrid(St_MakePoint(144.800244, -37.830869), 4326),
  ST_SetSrid(St_MakePoint(144.972303, -37.831201), 4326)
);
```

* you can swap 4 lines in the top of `los_range` to compare the performance difference between a single-point SQ, and a raster SQ.
