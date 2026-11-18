# site-images

Inputs for tests/verify_site_tools.py, which converts each file in
site-images/ with tools/site_images.c0 and checks every pixel of the result.
Each picture is 32 by 24 pixels and one flat colour, red 235, green 45, blue 90,
which the JPEGs keep to within one step. The test accepts four steps either
way on each channel, so it needs no reference image of its own.

- baseline.jpg, a baseline JPEG.
- progressive.jpg, a progressive JPEG.
- colour.png, an 8-bit RGB PNG.
- first-frame.gif, a GIF89a, of which the converter takes the first frame.

Every file in site-images/ is converted, so nothing else belongs there.
