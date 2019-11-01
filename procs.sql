CREATE OR REPLACE FUNCTION
  los_range(IN startloc GEOGRAPHY, IN endloc GEOGRAPHY)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
AS $$
  DECLARE
    start_elevation DOUBLE PRECISION;
    tot_distance DOUBLE PRECISION;
    cur_distance DOUBLE PRECISION;
    bearing DOUBLE PRECISION;
    cur_elevation DOUBLE PRECISION;
    step_size DOUBLE PRECISION;
    cur_loc GEOGRAPHY;

    -- end_elevation DOUBLE PRECISION;
    -- required_pitch DOUBLE PRECISION;
    -- min_height DOUBLE PRECISION;

    end_elevation RASTER;
    required_pitch RASTER;
    min_height RASTER;
  BEGIN
    start_elevation := detailed_height(startloc) + 2;
    -- end_elevation := detailed_height(endloc);
    end_elevation := detailed_height_raster(endloc);

    min_height := end_elevation;
    step_size := 4 * sqrt(2);
    bearing := ST_Azimuth(startloc, endloc);
    tot_distance := ST_Distance(startloc, endloc);
    required_pitch := pitch(start_elevation, end_elevation, tot_distance);

    cur_distance := step_size;
    WHILE cur_distance <= tot_distance LOOP
      cur_loc := ST_Project(startloc, cur_distance, bearing);
      cur_elevation := fast_height(cur_loc);

      IF cur_elevation IS NULL THEN
        RETURN -1.0;
      END IF;

      min_height := larger(min_height, required_elevation(required_pitch, tot_distance, start_elevation));

      cur_distance := cur_distance + step_size;
    END LOOP;

    PERFORM inspect(end_elevation);
    PERFORM inspect(required_pitch);
    PERFORM inspect(min_height);

    RETURN tot_distance;
  END;
$$;

------------------------------
-- return the larger of values
------------------------------
CREATE OR REPLACE FUNCTION
  larger(in val1 DOUBLE PRECISION, in val2 DOUBLE PRECISION)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
IMMUTABLE
AS $$
  BEGIN
    return greatest(val1, val2);
  END;
$$;

CREATE OR REPLACE FUNCTION
  larger(in rast1 RASTER, in rast2 RASTER)
RETURNS RASTER
LANGUAGE plpgsql
IMMUTABLE
AS $$
  DECLARE
    res RASTER;
  BEGIN
    SELECT ST_Union(tbl.rast, 'MAX')
    INTO res
    FROM (VALUES(rast1), (rast2)) tbl(rast);

    return res;
  END;
$$;

----------------------
-- poor man's debugger
----------------------
CREATE OR REPLACE FUNCTION
  inspect(in value DOUBLE PRECISION)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $$
  BEGIN
    RAISE NOTICE '%', value;
  END;
$$;


CREATE OR REPLACE FUNCTION
  inspect(in rast RASTER)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $$
  DECLARE
    stats RECORD;
  BEGIN
    SELECT ST_SummaryStats(rast) INTO stats;
    RAISE NOTICE '%', to_json(stats)->>'st_summarystats';
  END;
$$;

-------------------------------------------------------
-- required elevation at target location
-- need to subtract actual elevation to get mast height
-------------------------------------------------------
CREATE OR REPLACE FUNCTION
  required_elevation(IN pitch DOUBLE PRECISION, IN distance DOUBLE PRECISION, IN start_elevation DOUBLE PRECISION)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
IMMUTABLE
AS $$
  BEGIN
    -- R = 6370986.0
    -- 1 / (360 * R) = 0.0000000004360043763677675289
    return tan(distance * 0.0000000004360043763677675289 + pitch) * distance - start_elevation;
  END;
$$;

CREATE OR REPLACE FUNCTION
  required_elevation(IN pitch RASTER, IN height RASTER, IN distance DOUBLE PRECISION, IN start_elevation DOUBLE PRECISION)
RETURNS RASTER
LANGUAGE plpgsql
IMMUTABLE
AS $$
  DECLARE
    res RASTER;
  BEGIN
    SELECT
      ST_MapAlgebra(
        pitch,
        height,
        'greatest(tan(' || distance || ' * 0.0000000004360043763677675289 + [rast1.val]) * ' || distance || ' - ' || start_elevation || ', [rast2.val])'
      )
    INTO res;
    return res;
  END;
$$;

-----------------------------
-- the pitch required for LOS
-----------------------------
CREATE OR REPLACE FUNCTION
  pitch(IN start_elevation DOUBLE PRECISION, IN end_elevation DOUBLE PRECISION, IN distance DOUBLE PRECISION)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
IMMUTABLE
AS $$
  BEGIN
    -- R = 6370986.0
    -- 1 /  R = 0.000000156961575492396310
    return (atan((end_elevation - start_elevation) / distance)) - (distance * 0.000000156961575492396310);
  END;
$$;

CREATE OR REPLACE FUNCTION
  pitch(IN start_elevation DOUBLE PRECISION, IN end_elevation RASTER, IN distance DOUBLE PRECISION)
RETURNS RASTER
LANGUAGE plpgsql
IMMUTABLE
AS $$
  DECLARE
    res RASTER;
  BEGIN
    SELECT
      ST_MapAlgebra(
        end_elevation,
        1,
        NULL,
        '(atan(([rast.val] -' || start_elevation || ') / ' || distance || ')) - (' || distance * 0.000000156961575492396310 || ')'
      )
    INTO res;
    return res;
  END;
$$;

---------------------------------
-- high resolution elevation data
---------------------------------
CREATE OR REPLACE FUNCTION
  detailed_height(IN loc GEOGRAPHY)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
IMMUTABLE
AS $$
  DECLARE
    geom GEOMETRY;
    height DOUBLE PRECISION;
  BEGIN
    geom := ST_Transform(CAST(loc AS GEOMETRY), 7855);

    SELECT ST_Value(rast, geom)
    INTO height
    FROM elevation
    WHERE ST_Intersects(rast, geom)
    LIMIT 1;

    return height;
  END;
$$;

-----------------------------------------------
-- high resolution elevation data (in a raster)
-----------------------------------------------
CREATE OR REPLACE FUNCTION
  detailed_height_raster(IN loc GEOGRAPHY)
RETURNS RASTER
LANGUAGE plpgsql
IMMUTABLE
AS $$
  DECLARE
    geom GEOMETRY;
    envelope GEOMETRY;
    target RASTER;
  BEGIN
    geom := ST_Transform(CAST(loc AS GEOMETRY), 7855);

    SELECT
      ST_Envelope(
        ST_MakeEmptyRaster(
          1, 1,
          CAST((floor(ST_X(geom)) - 0.25) as float), CAST((floor(ST_Y(geom)) - 0.25) as float),
          4, 4,
          0, 0,
          7855
        )
      )
    INTO envelope;

    SELECT ST_Clip(ST_UNION(rast), envelope, true)
    INTO target
    FROM elevation -- change to other overviews to get the desired oversample ratio
    WHERE ST_Intersects(rast, envelope);

    return target;
  END;
$$;

-----------------------------------------------
-- low resolution elevation data
-- used to increase likelihood that RAM is warm
-----------------------------------------------
CREATE OR REPLACE FUNCTION
  fast_height(IN loc GEOGRAPHY)
RETURNS DOUBLE PRECISION
LANGUAGE plpgsql
IMMUTABLE
AS $$
  DECLARE
    geom GEOMETRY;
    height DOUBLE PRECISION;
  BEGIN
    geom := ST_Transform(CAST(loc AS GEOMETRY), 7855);

    SELECT ST_Value(rast, geom)
    INTO height
    FROM o_8_elevation
    WHERE ST_Intersects(rast, geom)
    LIMIT 1;

    return height;
  END;
$$;
