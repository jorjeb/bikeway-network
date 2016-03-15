package main

import (
	"database/sql"
	"fmt"
	"github.com/ant0ine/go-json-rest/rest"
	_ "github.com/lib/pq"
	"net/http"
	"os"
	"strconv"
)

type Point struct {
	Lng float64
	Lat float64
}

type Edge struct {
	FacilityT string `json:"facilityT"`
	Source    uint16 `json:"-"`
	Target    uint16 `json:"-"`
	Line1     string `json:"line1"`
	Line2     string `json:"line2"`
}

type Path struct {
	RouteID   uint8   `json:"routeID"`
	FacilityT string  `json:"facilityT"`
	Geometry  string  `json:"geometry"`
	Length    float64 `json:"length"`
}

var db *sql.DB

func main() {
	var err error

	db, err = sql.Open("postgres", "dbname= user= password= sslmode=disable")
	if err != nil {
		panic(err.Error())
	}
	defer db.Close()

	if err = db.Ping(); err != nil {
		panic(err.Error())
	}

	handler := rest.ResourceHandler{
		DisableXPoweredBy: true,
		DisableJsonIndent: true,
		PreRoutingMiddlewares: []rest.Middleware{
			&rest.CorsMiddleware{
				RejectNonCorsRequests: false,
				OriginValidator: func(origin string, request *rest.Request) bool {
					return origin == "http://localhost:9080"
				},
				AllowedMethods:                []string{"GET"},
				AllowedHeaders:                []string{"Accept", "Content-Type", "X-Custom-Header", "Origin"},
				AccessControlAllowCredentials: true,
				AccessControlMaxAge:           3600,
			},
		},
	}

	err = handler.SetRoutes(
		&rest.Route{"GET", "/paths/#lng1/#lat1/#lng2/#lat2", getPaths},
	)
	if err != nil {
		panic(err.Error())
	}

	bind := fmt.Sprintf("%s:%s", os.Getenv("HOST"), os.Getenv("PORT"))

	fmt.Printf("listening on %s...", bind)

	if err = http.ListenAndServe(bind, &handler); err != nil {
		panic(err.Error())
	}
}

func getPaths(w rest.ResponseWriter, r *rest.Request) {
	var err error
	var startLng float64
	var startLat float64
	var endLng float64
	var endLat float64
	var startEdge Edge
	var endEdge Edge
	var paths []Path

	numberOfPaths := 3

	startLng, err = strconv.ParseFloat(r.PathParam("lng1"), 64)
	if err != nil || startLng < -180 || startLng > 180 {
		rest.Error(w, "Longitude must be between -180 to 180", http.StatusBadRequest)
		return
	}

	startLat, err = strconv.ParseFloat(r.PathParam("lat1"), 64)
	if err != nil || startLat < -90 || startLat > 90 {
		rest.Error(w, "Latitude must be between -90 to 90", http.StatusBadRequest)
		return
	}

	endLng, err = strconv.ParseFloat(r.PathParam("lng2"), 64)
	if err != nil || endLng < -180 || endLng > 180 {
		rest.Error(w, "Longitude must be between -180 to 180", http.StatusBadRequest)
		return
	}

	endLat, err = strconv.ParseFloat(r.PathParam("lat2"), 64)
	if err != nil || endLat < -90 || endLat > 90 {
		rest.Error(w, "Latitude must be between -90 to 90", http.StatusBadRequest)
		return
	}

	if startEdge, err = findNearestEdge(Point{startLng, startLat}); err != nil {
		rest.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	if endEdge, err = findNearestEdge(Point{endLng, endLat}); err != nil {
		rest.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	query :=
		`SELECT
    a.id1 AS route_id,
    d.facility_t,
    ST_AsGeoJSON(
      ST_Transform(
        c.the_geom,
        4326
      )
    ) AS geometry,
    ST_Length(
      c.the_geom
    ) AS the_length
  FROM
    pgr_ksp(
      'SELECT
        id,
        source::integer,
        target::integer,
        ST_Length(the_geom)::double precision AS cost,
        ST_Length(the_geom)::double precision AS reverse_cost
      FROM
        sfmta_bikeway_network_noded',
      $1::integer,
      $2::integer,
      $3::integer,
      true
    ) a
  INNER JOIN
    sfmta_bikeway_network_noded c
  ON
    a.id3 = c.id
  INNER JOIN
    sfmta_bikeway_network d
  ON
    c.old_id = d.id`

	rows, err := db.Query(query, startEdge.Source, endEdge.Target, numberOfPaths)
	if err != nil {
		rest.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	defer rows.Close()

	for rows.Next() {
		var routeID uint8
		var facilityT []byte
		var geometry []byte
		var length float64

		if err = rows.Scan(&routeID, &facilityT, &geometry, &length); err != nil {
			rest.Error(w, err.Error(), http.StatusBadRequest)
			return
		}

		paths = append(paths, Path{routeID, string(facilityT), string(geometry), length})
	}

	w.WriteJson(struct {
		StartEdge Edge   `json:"startEdge"`
		EndEdge   Edge   `json:"endEdge"`
		Paths     []Path `json:"paths"`
	}{
		startEdge,
		endEdge,
		paths,
	})
}

func findNearestEdge(p Point) (Edge, error) {
	query :=
		`SELECT
    facility_t,
    source,
    target,
    ST_AsGeoJSON(
      ST_LineSubstring(
        the_geom,
        0,
        location
      )
    ) AS line1,
    ST_AsGeoJSON(
      ST_LineSubstring(
        the_geom,
        location,
        1
      )
    ) AS line2
  FROM
    (
    SELECT
      b.facility_t,
      a.source,
      a.target,
      ST_Transform(
        a.the_geom,
        4326
      ) AS the_geom,
      ST_LineLocatePoint(
        ST_Transform(
          a.the_geom,
          4326
        ),
        ST_SetSRID(
          ST_MakePoint(
            $1::double precision,
            $2::double precision
          ),
          4326
        )
      ) AS location
    FROM
      sfmta_bikeway_network_noded a
    LEFT JOIN
      sfmta_bikeway_network b
    ON
      a.old_id = b.id
    ORDER BY
      ST_Distance(
        ST_Transform(
          a.the_geom,
          4326
        ),
        ST_SetSRID(
          ST_MakePoint(
            $1::double precision,
            $2::double precision
          ),
          4326
        )
      )
    LIMIT 1
    ) AS t1`

	var edge Edge

	rows, err := db.Query(query, p.Lng, p.Lat)
	if err != nil {
		return edge, err
	}
	defer rows.Close()

	for rows.Next() {
		var facilityT []byte
		var source uint16
		var target uint16
		var line1 []byte
		var line2 []byte

		if err = rows.Scan(&facilityT, &source, &target, &line1, &line2); err != nil {
			return edge, err
		}

		edge.FacilityT = string(facilityT)
		edge.Source = source
		edge.Target = target
		edge.Line1 = string(line1)
		edge.Line2 = string(line2)
	}

	return edge, nil
}
