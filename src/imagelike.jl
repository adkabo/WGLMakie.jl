using AbstractPlotting: el32convert, surface_normals, get_dim


function draw_mesh(mscene::Scene, mesh, plot; uniforms...)
    uniforms = Dict(uniforms)

    colormap = if haskey(plot, :colormap)
        cmap = lift(el32convert ∘ to_colormap, plot.colormap)
        uniforms[:colormap] = Sampler(cmap)
    end

    colorrange = if haskey(plot, :colorrange)
        uniforms[:colorrange] = lift(Vec2f0, plot.colorrange)
    end

    get!(uniforms, :colormap, false)
    get!(uniforms, :colorrange, false)
    get!(uniforms, :color, false)
    get!(uniforms, :model, plot.model)

    return Program(WebGL(), lasset("mesh.vert"), lasset("mesh.frag"), mesh; uniforms...)
end

function limits_to_uvmesh(plot)
    px, py = plot[1], plot[2]
    rectangle = lift(px, py) do x, y
        xmin, xmax = extrema(x)
        ymin, ymax = extrema(y)
        return Rect2D(xmin, ymin, xmax - xmin, ymax - ymin)
    end

    positions = Buffer(lift(x -> decompose(Point2f0, x), rectangle))
    faces = Buffer(lift(x -> decompose(GLTriangleFace, x), rectangle))
    uv = Buffer(lift(decompose_uv, rectangle))

    vertices = GeometryBasics.meta(positions; uv=uv)

    return GeometryBasics.Mesh(vertices, faces)
end

function create_shader(mscene::Scene, plot::Surface)
    # TODO OWN OPTIMIZED SHADER ... Or at least optimize this a bit more ...
    px, py, pz = plot[1], plot[2], plot[3]
    function grid(x, y, z)
        g = map(CartesianIndices(z)) do i
            return Point3f0(get_dim(x, i, 1, size(z)), get_dim(y, i, 2, size(z)), z[i])
        end
        return vec(g)
    end
    positions = Buffer(lift(grid, px, py, pz))
    rect = lift(z -> Tesselation(Rect2D(0f0, 0f0, 1f0, 1f0), size(z)), pz)
    faces = Buffer(lift(r -> decompose(GLTriangleFace, r), rect))
    uv = Buffer(lift(decompose_uv, rect))
    pcolor = if haskey(plot, :color) && plot.color[] isa AbstractArray
        plot.color
    else
        pz
    end
    minfilter = to_value(get(plot, :interpolate, false)) ? :linear : :nearest
    color = Sampler(lift(x -> el32convert(x'), pcolor), minfilter=minfilter)
    normals = Buffer(lift(surface_normals, px, py, pz))
    vertices = GeometryBasics.meta(positions; uv=uv, normals=normals)
    mesh = GeometryBasics.Mesh(vertices, faces)
    return draw_mesh(mscene, mesh, plot; uniform_color=color, color=Vec4f0(0),
                     shading=plot.shading, ambient=plot.ambient, diffuse=plot.diffuse,
                     specular=plot.specular, shininess=plot.shininess,
                     lightposition=Vec3f0(1))
end

function create_shader(mscene::Scene, plot::Union{Heatmap,Image})
    image = plot[3]
    color = Sampler(map(x -> el32convert(x'), image);
                    minfilter=to_value(get(plot, :interpolate, false)) ? :linear : :nearest)
    mesh = limits_to_uvmesh(plot)

    return draw_mesh(mscene, mesh, plot; uniform_color=color, color=Vec4f0(0),
                     normals=Vec3f0(0), shading=false, ambient=plot.ambient,
                     diffuse=plot.diffuse, specular=plot.specular,
                     colorrange=haskey(plot, :colorrange) ? plot.colorrange : false,
                     shininess=plot.shininess, lightposition=Vec3f0(1))
end

function create_shader(mscene::Scene, plot::Volume)
    x, y, z, vol = plot[1], plot[2], plot[3], plot[4]
    box = GeometryBasics.mesh(FRect3D(Vec3f0(0), Vec3f0(1)))
    cam = cameracontrols(mscene)
    model2 = lift(plot.model, x, y, z) do m, xyz...
        mi = minimum.(xyz)
        maxi = maximum.(xyz)
        w = maxi .- mi
        m2 = Mat4f0(w[1], 0, 0, 0, 0, w[2], 0, 0, 0, 0, w[3], 0, mi[1], mi[2], mi[3], 1)
        return convert(Mat4f0, m) * m2
    end

    modelinv = lift(inv, model2)
    algorithm = lift(x -> Cuint(convert_attribute(x, key"algorithm"())), plot.algorithm)

    return Program(WebGL(), lasset("volume.vert"), lasset("volume.frag"), box,
                   volumedata=Sampler(lift(AbstractPlotting.el32convert, vol)),
                   modelinv=modelinv, colormap=Sampler(lift(to_colormap, plot.colormap)),
                   colorrange=lift(Vec2f0, plot.colorrange),
                   isovalue=lift(Float32, plot.isovalue),
                   isorange=lift(Float32, plot.isorange),
                   absorption=lift(Float32, get(plot, :absorption, Observable(1f0))),
                   algorithm=algorithm, ambient=plot.ambient,
                   diffuse=plot.diffuse, specular=plot.specular, shininess=plot.shininess,
                   model=model2,
                   # these get filled in later by serialization, but we need them
                   # as dummy values here, so that the correct uniforms are emitted
                   lightposition=Vec3f0(1), eyeposition=Vec3f0(1))
end
