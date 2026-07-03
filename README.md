 [![Code of Conduct](https://img.shields.io/badge/%E2%9D%A4-code%20of%20conduct-blue.svg?style=flat)](https://github.com/edgi-govdata-archiving/overview/blob/main/CONDUCT.md)

# EJAM-API
In February 2025, USEPA removed its EJSCREEN website from public access, including an API for querying EJSCREEN indices/indicators and Census data. One of the main features of the API was geographically-based inquiries. It could be used to, for instance, return EJSCREEN and Census metrics weighted based on the Census Blocks within a 3 mile buffer around a selected point. The API facilitated the creation of [community reports](https://www.sf.gov/sites/default/files/2024-03/EJScreen%20Community%20Report.pdf) based on those kinds of queries. 

Recreating that API would require extensive reverse engineering of the ArcGIS map server(s) that hosted the API functionality. Instead, our approach is to draw on [EJAM](https://github.com/ejanalysis/EJAM), the non-EPA version of an open-source R package that provides EJSCREEN's "multisite" reporting feature. EJAM was designed to produce EJSCREEN-style community reports, including single-site reports and multisite reports (summaries over multiple locations). The EJAM package itself does not currently provide an API; this repo contains files necessary to create a Docker image of EJAM and its dependencies as well as an API model.

# Model
The API exposes report and data endpoints, plus a token-based handoff for launching the [EJAM app](https://ejanalysis.org/ejamapp) pre-loaded with sites already specified as parameters.

## Base URLs
The canonical base URL is the Cloud Run service:
`https://ejamapi-84652557241.us-central1.run.app`

A friendlier base URL is also available now and proxies the **same** API through Cloudflare (with permissive CORS for browser apps):
`https://api.ejanalysis.com` (and the alias `https://ejamapi.ejanalysis.com`)

All of the example URLs below work with either base. For example, `https://api.ejanalysis.com/report?fips=10001` is equivalent to using the Cloud Run URL.
The [EJAM R package](https://ejanalysis.org/ejamdocs) reads its API base from one place, the `ejam_api_url` field in its `DESCRIPTION` file, so it can point at either base; see `?url_package` and [url_ejamapi](https://public-environmental-data-partners.github.io/EJAM/reference/url_ejamapi.html) in EJAM.

Visiting a base URL with no path (e.g. `https://api.ejanalysis.com/`) redirects to this repo's interactive API documentation page (`/__docs__/`).

## Reports

The `report` endpoint returns a PDF or HTML report for one or more sites specified by
point, area (polygon), or FIPS geography.

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
A report on one county: https://api.ejanalysis.com/report?fips=10001

A report on residents within a 1 mile radius (buffer) of one point in the Phoenix area: https://api.ejanalysis.com/report?lat=33&lon=-112&buffer=1

A multisite report over two points, 3 mile radius, as pdf: https://ejamapi-84652557241.us-central1.run.app/report?lat=33,34&lon=-112,-114&buffer=3&sitenumber=0&fileextension=pdf

A multisite report over two counties, as html: https://ejamapi-84652557241.us-central1.run.app/report?fips=10001,10003&sitenumber=0&fileextension=html

A rectangular area of interest in Phoenix, with no buffer: https://ejamapi-84652557241.us-central1.run.app/report?shape=%7B"type"%3A"FeatureCollection"%2C"features"%3A%5B%7B"type"%3A"Feature"%2C"properties"%3A%7B%7D%2C"geometry"%3A%7B"coordinates"%3A%5B%5B%5B-112.01991856401462%2C33.51124624304089%5D%2C%5B-112.01991856401462%2C33.47010908826502%5D%2C%5B-111.95488826248605%2C33.47010908826502%5D%2C%5B-111.95488826248605%2C33.51124624304089%5D%2C%5B-112.01991856401462%2C33.51124624304089%5D%5D%5D%2C"type"%3A"Polygon"%7D%7D%5D%7D&buffer=0

### Multisite report via POST

`report` also accepts **POST** requests, for multisite reports over **many or large polygons** (or large site sets) that would not fit in a GET URL. It uses the same report engine and accepts `sites`, `shape`, `fips`, and `buffer` (like `data`, but `scale` is not used for reports -- each FIPS is reported as its own site). Provide exactly one of `sites`, `shape`, or `fips` per request, plus:
- `sitenumber` - default `0` = aggregate **multisite report**; a positive integer reports on that one site.
- `fileextension` - `pdf` (default) or `html`.

Each `fips` code is a separate site. `shape` is a GeoJSON FeatureCollection string (one or more polygons). Returns the rendered report (HTML or PDF), same as GET `/report`.

```
# A multisite report over several drawn polygons
import json, requests
payload = {"shape": json.dumps(feature_collection), "buffer": 0, "sitenumber": 0, "fileextension": "html"}
html = requests.post("https://ejamapi-84652557241.us-central1.run.app/report", json=payload).text
```

## Data

The `data` endpoint returns a JSON object of EJAM output for a given point, area, or FIPS geography.

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

## Query
`query` accepts POST requests with the following parameters:
- `attribute` - an EJSCREEN attribute in EJAM syntax, such as `pctlowinc` or `pctunemployed`
- `value` - a decimal cutoff from 0 to 1; numeric-like strings are coerced and invalid values are rejected
- `page` - a positive whole-number page to return. Default = 1
- `limit` - rows per page. Default = 100; maximum = 500

`query` returns a JSON object with:
- `results` - the EJAM output rows for the requested page
- `pagination` - metadata with `page`, `limit`, `total_rows`, `total_pages`, `returned_rows`, `has_next_page`, and `has_previous_page`

Pagination is 1-based. For example, with `limit = 100`, `page = 2` returns rows 101-200 from the query results. If `page` is beyond the available results, `results` is empty and `pagination` still reports the total row and page counts.

### Examples
```
data = {"attribute": "pctlowinc", "value": 0.95, "page": 1, "limit": 100}

# Execute query
import requests
url = "https://ejamapi-84652557241.us-central1.run.app/query"
response = requests.post(url, json=data)

# Load response as Pandas dataframe
payload = response.json()
df = pandas.DataFrame.from_dict(payload["results"])
df

# Request the next page
data["page"] = payload["pagination"]["page"] + 1
response = requests.post(url, json=data)
```

## Handoff (launch the EJAM app pre-loaded)

Two endpoints let an external app (e.g. EJScreen) hand a set of selected places to the full EJAM app without hitting URL-length limits (important for polygons):

- `POST /handoff` — body may contain `sites` (array of `{lat,lon}`), `fips` (array of codes), `shape` (a GeoJSON `FeatureCollection`), and `radius`. Returns `{"token": "...", "expires": <epoch seconds>}`.
- `GET /handoff/<token>` — returns the stored payload as JSON.

The caller opens the EJAM app at `https://ejam.publicenvirodata.org/?handoff=<token>`; the app fetches `GET /handoff/<token>` on startup and pre-loads those places.

> The current store is in-process with a 1-hour TTL and bounded capacity. By default, `POST /handoff` accepts payloads up to 1 MiB (`HANDOFF_MAX_PAYLOAD_BYTES=1048576`) and up to 64 active tokens (`HANDOFF_MAX_TOKENS=64`) before returning an error. Token-collision retries are bounded (`HANDOFF_TOKEN_COLLISION_RETRIES=8`). On Cloud Run with more than one instance, a token created on one instance will not resolve on another — use a shared store (GCS/Firestore/Redis) or run with `min-instances=1` and a single max instance.

## CORS

All routes send `Access-Control-Allow-Origin: *` and answer `OPTIONS` preflight requests, so browser apps can `fetch()`/POST cross-origin (needed for `/handoff` and any future POST report endpoint). The single-site report flow uses a top-level `window.open()` GET and does not depend on CORS.

## Assets

An assets endpoint returns a file from a pre-defined set of assets. The endpoint is structured as `/assets/<asset_name>`, 
where `<asset_name>` is the name of the asset file. 
For example, to retrieve a specific asset, you would make a GET request to `/assets/example_asset.pdf`.

# Set-up
1. Work locally with EJAM by installing R/RStudio. Follow the [installation instructions](https://ejanalysis.github.io/EJAM/articles/installing.html) in the [EJAM documentation](https://ejanalysis.org/ejamdocs).
2. Test changes to the API (i.e. modify `rest_controller.r`)
3. Re-build and tag the Docker image (the EJAM version is controlled by the `EJAM_VERSION` build arg — see below)
4. Push to Docker Hub and/or Google Artifact Registry
5. Re-deploy in Google Cloud Run

## Choosing the EJAM version

The version of the [EJAM](https://github.com/Public-Environmental-Data-Partners/EJAM) package baked into the image is set in **one place**: the `EJAM_VERSION` build argument in the [`Dockerfile`](/Dockerfile) (default `v2.32.8.1`, matching the version the image currently deploys). This value is passed directly to `git clone --branch`, so it must be a valid git ref — typically a tag like `v2.32.8.1` (include the leading `v`), though a branch name such as `development` also works (see below). That's the only line to change when bumping versions — the clone uses a fixed scratch directory (`/EJAM_src`), so the version no longer has to be repeated across the clone, install, and cleanup steps.

- **Override at build time** (no Dockerfile edit), e.g. `docker build --build-arg EJAM_VERSION=v3.2022.0 .` or `docker build --build-arg EJAM_VERSION=v3.2023.0 .`
- **Deploy from a branch** instead of a tagged release: pass the branch name with no leading `v`, e.g. `docker build --build-arg EJAM_VERSION=development .`. A branch is a moving target but the `git clone` image layer is cached, so a plain rebuild may reuse an earlier clone of that branch — add `--no-cache` to force a fresh pull of the current branch tip: `docker build --no-cache --build-arg EJAM_VERSION=development .`. (Tagged releases are immutable, so their cached layer is always correct.)
- **Control it at the repo level:** set a GitHub Actions repository variable named `EJAM_VERSION` (Settings → Secrets and variables → Actions → Variables), and have the image-build step pass it through with `--build-arg EJAM_VERSION=${{ vars.EJAM_VERSION }}`. (This repo currently builds the image manually per the steps above; that variable is consumed automatically once an image-build workflow is added.)
- The selected version is also recorded in the image as the `EJAM_VERSION` environment variable, so the running API can report which EJAM release it was built with.

---

## License & Copyright

Copyright (C) <year> Environmental Data and Governance Initiative (EDGI)
This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.0.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

See the [`LICENSE`](/LICENSE) file for details.
