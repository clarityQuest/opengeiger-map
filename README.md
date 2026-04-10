# Elevated Radiation Map

Interactive map of locations with elevated or unusual radiation readings, combining opengeiger.de and Geigerzählerforum entries.

The map helps you quickly scan where these locations are and compare reported dose rates across both sources. Each marker shows:

- the location name
- a short note
- the reported dose rate (uSv/h)
- a direct link to the original source entry
- a button to open the location in Google Maps

You can also show your own current position on the map to see nearby entries, and toggle sources directly in the legend.

Live webpage (GitHub Pages):
https://clarityQuest.github.io/opengeiger-map/

If GitHub Pages is still deploying and returns 404, open the map directly from this repository:
https://github.com/clarityQuest/opengeiger-map/blob/main/index.html

## Data Sources and Credits

- Location list, notes, and dose values: opengeiger.de Geiger Caching page  
	http://www.opengeiger.de/GeigerCaching/GeigerCaching.html
- Basemap and geographic data attribution: OpenStreetMap contributors  
	https://www.openstreetmap.org/copyright
- Mapping framework: Leaflet  
	https://leafletjs.com/
