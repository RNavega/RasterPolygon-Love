# RasterPolygon-Love
Rasterizing a polygonal shape directly in a Lua script, creating a grayscale image (R8 format) out of it.  

![Preview](https://github.com/RNavega/RasterPolygon-Love/assets/28221053/0decdf9f-9825-463b-9c73-40dd030561c0)

The shape data in your game assets would use less storage space than an image, as well as being scalable -- say, for UI elements whose final size is based on the user's screen, so you rasterize the shape(s) scaled into that size instead of having to ship with one or more bitmaps for different sizes that you think you might need.

First you draw your shapes in something like Inkscape:  

![Inkscape Screenshot](https://github.com/RNavega/RasterPolygon-Love/assets/28221053/85623a6e-777e-44d5-bdf7-9c83c9bc0f33)

Then also in Inkscape you press Ctrl + Shift + X to open the XML editor, where you can access the path object for your shapes and copy the contents of their "d" attribute (the list of SVG drawing commands).  
Make sure that the SVG only uses linear drawing commands (M / m, L / l, H / h and V / v). You can quickly convert things like circles and curves to those linear shapes, by using either Extensions > Modify Path > Flatten Beziers, or by selecting all nodes in the path and then clicking "Insert new node" so that new nodes are inserted inbetween them, repeating this as much as needed, then finally selecting all nodes and changing their type to linear.  
You can paste the commands in your Lua scripts as a \[\[ multiline string \]\], adding line breaks etc, using the double bracket syntax ([example](https://github.com/RNavega/RasterPolygon-Love/blob/master/main.lua#L38-L66)).

### Other resources:
- [TÖVE](https://github.com/poke1024/tove2d) (a feature-packed SVG library for Löve by poke1024)
