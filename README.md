 [![Code of Conduct](https://img.shields.io/badge/%E2%9D%A4-code%20of%20conduct-blue.svg?style=flat)](https://github.com/edgi-govdata-archiving/overview/blob/main/CONDUCT.md)

# EJAM-API
In February 2025, USEPA removed its EJSCREEN website from public access, including an API for querying EJSCREEN indices/indicators and Census data. One of the main features of the API was geographically-based inquiries. It could be used to, for instance, return EJSCREEN and Census metrics weighted based on the Census Blocks within a 3 mile buffer around a selected point. The API facilitated the creation of [community reports](https://www.sf.gov/sites/default/files/2024-03/EJScreen%20Community%20Report.pdf) based on those kinds of queries. 

Recreating that API would require extensive reverse engineering of the ArcGIS map server(s) that hosted the API functionality. Instead, our approach is to draw on [EJAM](https://github.com/ejanalysis/EJAM), the non-EPA version of an open-source R package that provides EJSCREEN's "multisite" reporting feature. EJAM was designed to produce EJSCREEN-style community reports, including single-site reports and multisite reports (summaries over multiple locations). The EJAM package itself does not currently provide an API; this repo contains files necessary to create a Docker image of EJAM and its dependencies as well as an API model.

# Model
The API exposes report and data endpoints, plus a token-based handoff for launching the EJAM app pre-loaded.

## Reports
`report` accepts GET requests with the following parameters:
- `lat` - the latitude of a given point, or comma-separated list like lat=33,32.5
- `lon` - the longitude
- `fips` - A FIPS code for a specific US Census geography, like fips=10 for one state, or comma-separated list like fips=10001,10003,10005 for 3 counties
- `shape` - a GeoJSON text-encoded object describing an area of interest, such as a polygon of neighborhood boundaries
- `buffer` (or `radius`, a synonym) - radius, in miles, around a point or out from the edge of a polygon to extend the search. EJAM default = 3. *Note: adding buffers around fips units may not be implemented yet.
- `sitenumber` - which site to report on when more than one is supplied. Default = 1 (a single-site report on the first site). Use `sitenumber=0` (or `sitenumber=overall`) to get an aggregate **multisite report** that summarizes all of the supplied sites together. Each comma-separated `fips` code is treated as a separate site (no expansion), so `fips=10001,10003&sitenumber=0` reports on those two counties together.
- `fileextension` - `pdf` (default) or `html`.

`report` expects either `lat`/`lon` OR `shape` OR `fips`. The default buffer around a point is 3 miles but can be explicitly set to 0. With `fileextension=html`, an HTML report is returned; otherwise a PDF.

### Examples
A County: https://ejamapi-84652557241.us-central1.run.app/report?buffer=1&fips=10001

A point in the Phoenix area with a 4 mile buffer (radius): https://ejamapi-84652557241.us-central1.run.app/report?lat=33&lon=-112&buffer=4

A multisite report over two points: https://ejamapi-84652557241.us-central1.run.app/report?lat=33,34&lon=-112,-114&buffer=3&sitenumber=0&fileextension=html

A multisite report over two counties: https://ejamapi-84652557241.us-central1.run.app/report?fips=10001,10003&sitenumber=0&fileextension=html

A rectangular area of interest in Phoenix, with no buffer: https://ejamapi-84652557241.us-central1.run.app/report?shape=%7B"type"%3A"FeatureCollection"%2C"features"%3A%5B%7B"type"%3A"Feature"%2C"properties"%3A%7B%7D%2C"geometry"%3A%7B"coordinates"%3A%5B%5B%5B-112.01991856401462%2C33.51124624304089%5D%2C%5B-112.01991856401462%2C33.47010908826502%5D%2C%5B-111.95488826248605%2C33.47010908826502%5D%2C%5B-111.95488826248605%2C33.51124624304089%5D%2C%5B-112.01991856401462%2C33.51124624304089%5D%5D%5D%2C"type"%3A"Polygon"%7D%7D%5D%7D&buffer=0

### Multisite report via POST

`report` also accepts **POST** requests, for multisite reports over **many or large polygons** (or large site sets) that would not fit in a GET URL. It uses the same report engine and accepts `sites`, `shape`, `fips`, and `buffer` (like `data`, but `scale` is not used for reports -- each FIPS is reported as its own site). Provide exactly one of `sites`, `shape`, or `fips` per request, plus:
- `sitenumber` - default `0` = aggregate **multisite report**; a positive integer reports on that one site.
- `fileextension` - `html` (default) or `pdf`.

Each `fips` code is a separate site. `shape` is a GeoJSON FeatureCollection string (one or more polygons). Returns the rendered report (HTML or PDF), same as GET `/report`.

```
# A multisite report over several drawn polygons
import json, requests
payload = {"shape": json.dumps(feature_collection), "buffer": 0, "sitenumber": 0, "fileextension": "html"}
html = requests.post("https://ejamapi-84652557241.us-central1.run.app/report", json=payload).text
```

## Data
`data` accepts POST requests with the following parameters:
- `sites` - a list of lat/lon pairs e.g. `[{"lat":33, "lon":-112}, {"lat":34, "lon":-114}]`
- `shape` - a GeoJSON object describing an area of interest, such as a polygon of neighborhood boundaries
- `buffer` - radius, in miles, around the center of a point or out from the edge of a polygon to extend the search. Default = 0
- `fips` - A FIPS code for a specific US Census geography (e.g. 10001)
- `scale` - For FIPS requests, the unit of at which to return results (county or blockgroup)
- `geometries` - A boolean to indicate whether to return a geometry field for each analyzed unit. Default = FALSE

`data` expects either `sites` OR `shape` OR `fips`. 
A JSON object of EJAM output is returned.

### Examples
```
# Queries
import json
with open('houston_zips.json', 'r') as f:
  houston_zips = json.load(f)
data = {"buffer":0,"shape":json.dumps(houston_zips)} # Using a previously loaded GeoJSON of zipcodes in Houston
data = {"buffer": 1, "shape": json.dumps(simple_shape), "geometries": True} # Using a previously loaded simple GeoJSON feature, and returning its geometry
data = {"buffer": 4, "sites": [{"lat":33, "lon":-112}]} # A single set of coordinates
data = {"buffer": 4, "sites": [{"lat":33, "lon":-112}, {"lat":34, "lon":-114}]} # Two or more sets of coordinates
data = {"buffer": 0, "fips": ["482012301001","482012302002", "482012302003"], "scale":"blockgroup"} # Four blockgroups
data = {"buffer": 0, "fips": "DE", "scale": "blockgroup"} # One state, returning results at the blockgroup level
data = {"buffer": 0, "fips": "DE", "scale": "county"} # One state with county level results
data = {"buffer": 0, "fips": ["DE", "RI"], "scale": "county"} # Two states, county level results

# Execute data query
import requests
url = "https://ejamapi-84652557241.us-central1.run.app/data"
response = requests.post(url, json=data)

# Load response as Pandas dataframe
df = pandas.DataFrame.from_dict(response.json())
df
```

## Handoff (launch the EJAM app pre-loaded)

Two endpoints let an external app (e.g. EJScreen) hand a set of selected places to the full EJAM app without hitting URL-length limits (important for polygons):

- `POST /handoff` — body may contain `sites` (array of `{lat,lon}`), `fips` (array of codes), `shape` (a GeoJSON `FeatureCollection`), and `radius`. Returns `{"token": "...", "expires": <epoch seconds>}`.
- `GET /handoff/<token>` — returns the stored payload as JSON.

The caller opens the EJAM app at `https://ejam.publicenvirodata.org/?handoff=<token>`; the app fetches `GET /handoff/<token>` on startup and pre-loads those places.

> The current store is in-process with a 1-hour TTL. On Cloud Run with more than one instance, a token created on one instance will not resolve on another — use a shared store (GCS/Firestore/Redis) or run with `min-instances=1` and a single max instance.

## CORS

All routes send `Access-Control-Allow-Origin: *` and answer `OPTIONS` preflight requests, so browser apps can `fetch()`/POST cross-origin (needed for `/handoff` and any future POST report endpoint). The single-site report flow uses a top-level `window.open()` GET and does not depend on CORS.

# Set-up
1. Work locally with EJAM by installing R/RStudio. Follow the [installation instructions](https://ejanalysis.github.io/EJAM/articles/installing.html) in the [EJAM documentation](https://ejanalysis.org/ejamdocs).
2. Test changes to the API (i.e. modify `rest_controller.r`)
3. Re-build and tag the Docker image
4. Push to Docker Hub and/or Google Artifact Registry
5. Re-deploy in Google Cloud Run

---

## License & Copyright

Copyright (C) <year> Environmental Data and Governance Initiative (EDGI)
This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.0.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the [`LICENSE`](/LICENSE) file for details.
