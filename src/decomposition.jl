_getrootmasterannotation(tree) = tree.root.master

# Should return the annotation corresponding to the vector of AxisId.
# Example :
# if axisids = [], the element goes in the master
# if axisids = [AxisIds(1)], the element goes in the subproblem with index 1
# todo : support nesting decomposition
function _getannotation(tree, axisids::Vector{AxisId})
    length(axisids) == 0 && return _getrootmasterannotation(tree)
    length(axisids) > 1 && error("BlockDecomposition does not support nested decomposition yet.")
    return tree.root.subproblems[axisids[1]].problem
end

function _annotate_elements!(model::JuMP.Model, container::JC.DenseAxisArray, tree)
    axisids = Vector{AxisId}()
    indice_sets = collect(Iterators.product(container.axes...))

    for indice_set in indice_sets # iterate over all the indice sets of the JuMP object
        for indice in indice_set # iterate over all indices of the current indice set
            if indice isa AxisId
                push!(axisids, indice)
            end
        end
        ann = _getannotation(tree, axisids)
        setannotation!(model, container[indice_set...], ann)
        empty!(axisids)
    end
    return
end

function _annotate_elements!(model::JuMP.Model, container::JC.SparseAxisArray, tree)
    axisids = Vector{AxisId}()
    container_keys = collect(keys(container.data))
    for key in container_keys # iterate over all indices of the container
        for indice in key
            if indice isa AxisId
                push!(axisids, indice)
            end
        end
        ann = _getannotation(tree, axisids)
        setannotation!(model, container[key...], ann)
        empty!(axisids)
    end
    return
end

function _annotate_elements!(model::JuMP.Model, container::JuMP.ConstraintRef, tree)
    setannotation!(model, container, _getrootmasterannotation(tree))
    return
end

function _annotate_elements!(model::JuMP.Model, container::JuMP.VariableRef, tree)
    setannotation!(model, container, _getrootmasterannotation(tree))
    return
end

function _annotate_elements!(model::JuMP.Model, container::AbstractArray, tree)
    for element in container
        setannotation!(model, element, _getrootmasterannotation(tree))
    end
    return
end


function new_register_decomposition(model::JuMP.Model)
    # Link to the tree
    tree = gettree(model)
    for (key, jump_obj) in model.obj_dict
        _annotate_elements!(model, jump_obj, tree)
    end
    return
end

"""
    register_decomposition(model)

Assign to each variable and constraint an annotation indicating in 
which partition (master/subproblem) of the original formulation the variable 
or the constraint is located.
"""
function register_decomposition(model::JuMP.Model)
    # First, we retrieve the decomposition axes associated to each JuMP object.
    # If there is no axis linked to a JuMP object, elements of the object are
    # in the master.
    # form an array of tuples, one tuple for each JuMP object, where each tuple consists of the object name (symbol) and an array containing the decomposition axes
    obj_axes = Vector{Tuple{Symbol, Vector{Axis}}}()
    for (key, jump_obj) in model.obj_dict
        dec_axes = look_for_dec_axis(tree, jump_obj)
        push!(obj_axes, (key, dec_axes))
    end
    
    # We sort JuMP objects according to the number of decomposition performed
    # over them.
    sort!(obj_axes, by = e -> length(e[2]), rev = true)

    # sort subproblems by depth in decomposition tree
    dec_nodes = getnodes(gettree(model))
    sort!(dec_nodes, by = n -> get_depth(n), rev = true)

    # associate JuMP objects to subproblems
    # annotate all JuMP objects with their association to master or subproblems
    for dec_node in dec_nodes
        println("\e[31m dec_node = $dec_node \e[00m")
        # get for all decomposition axes of the current node their current indices
        elem_axes_in_partition = get_elems_of_axes_in_node(dec_node)
        for (key, dec_axes) in obj_axes # iterate through all JuMP objects
            println("\e[32m JuMP object is $key \e[00m")
            if length(dec_axes) == length(elem_axes_in_partition) # check if subproblem is indexed over as many decomposition axes as JuMP object
                println("\e[33m \t indexed \e[00m")
                obj_ref = model.obj_dict[key] # get reference to JuMP object
                indices = get_indices_of_obj_in_partition(obj_ref, elem_axes_in_partition)
                println("\e[34m \t indices = $indices \e[00m")
                setannotations!(model, obj_ref, indices, annotation(dec_node))
            end
            (length(dec_axes) < length(elem_axes_in_partition)) && break
        end
    end
    return
end


"""
    look_for_dec_axis(tree::Tree, container::JC.DenseAxisArray)

This function checks for all index sets of a JuMP DenseAxisArray, if any indices of the set are part of a decomposition axis and returns an array containing those decomposition axes (empty if JuMP object is not defined over any decomposition axis).
"""
function look_for_dec_axis(tree::Tree, container::JC.DenseAxisArray)::Vector{Axis}
    dec_axes = Vector{Axis}()

    # iterate over all index sets of the object
    for axis in container.axes
        length(axis) == 0 && error("Empty JuMP objects currently unsupported: Open an issue at https://github.com/atoptima/BlockDecomposition.jl")
        # iterate over all indices of the current index set
        for indice in axis
          if indice isa AxisId
            push!(dec_axes, tree.decomposition_axes[name(indice)])
            break   # add axis only once to array
          end
        end

    end
    return dec_axes
end


"""
    look_for_dec_axis(tree::Tree, container::JC.SparseAxisArray)

This function checks if any indices of the JuMP SparseAxisArray are part of decomposition axes and returns an array containing those decomposition axes (empty if JuMP object is not defined over any decomposition axis).
"""
function look_for_dec_axis(tree::Tree, container::JC.SparseAxisArray)::Vector{Axis}
    dec_axes = Vector{Axis}()
    container_keys = collect(keys(container.data)) # get indices; as SparseAxisArrays are dictionaries it returns an array of tuples
    length(container_keys) == 0 && error("Empty JuMP objects currently unsupported: Open an issue at https://github.com/atoptima/BlockDecomposition.jl")

    # iterate over all indices of the JuMP object
    for indice in container_keys  # indice holds a tuple, the actual indice is contained in the first element of the tuple
        if indice[1] isa AxisId   
            push!(dec_axes, tree.decomposition_axes[name(indice[1])])
            break   # add axis only once to array
        end
    end
    return dec_axes
end

look_for_dec_axis(tree, constr::JuMP.ConstraintRef) = Vector{Axis}()
look_for_dec_axis(tree, var::JuMP.VariableRef) = Vector{Axis}()
look_for_dec_axis(tree, vars::Array{<:JuMP.VariableRef, N}) where N =  Vector{Axis}()
look_for_dec_axis(tree, constrs::Array{<:JuMP.ConstraintRef, N}) where N =  Vector{Axis}()

# get_indices_of_obj_in_partition returns the indices of the elements of the
# JuMP object that are in the partition defined by dec_axes_val.
# Consider an axis named :A with AxisId values [1,2,3,4]. 
# Assume we want the indices of the variable x[a in A, b in 1:5] that are in the
# partition defined by dec_axes_val = Dict(:A => 4) 
# get_indices_of_obj_in_partition returns the tuple (4,:) meaning that variables
# x[4,:] are in the subproblem with indice 4.
function get_indices_of_obj_in_partition(obj_ref::JC.DenseAxisArray, dec_axes_val)
    indices = Tuple[]

    # create an iterable collection of all possible combinations of the JuMP object indices (indice sets)
    indice_sets = collect(Iterators.product(obj_ref.axes...))

    for indice_set in indice_sets # iterate over all the indice sets of the JuMP object
        for indice in indice_set # iterate over all indices of the current indice set
            # add the current indice set if the one indice is an AxisID and it is contained in a decomposition axis of the current node
            if indice isa AxisId && name(indice) in keys(dec_axes_val) && indice == dec_axes_val[name(indice)]
                push!(indices, indice_set)
                break   # not required to check other indices anymore
            end
        end
    end
    return indices
end

function get_indices_of_obj_in_partition(
    obj_ref::JC.SparseAxisArray, dec_axes_val
)
    indices = Tuple[]
    container_keys = collect(keys(obj_ref.data))
    for key in container_keys
        keep = true
        axis_found = 0
        for indice in key # iterate over all indices of the current index set
            if indice isa AxisId
                for (axis_name, value) in dec_axes_val # iterate over all subproblem decomposition axes
                    if name(indice) == axis_name && indice != value # check if both JuMP object and subproblem are indexed over current axis, but their indices do not match
                        keep = false # in that case the indice is not kept
                    else
                        axis_found += 1
                    end
                end
            end
            if keep && axis_found == length(dec_axes_val)
                push!(indices, key)
            end
        end
    end
    return indices
end

get_indices_of_obj_in_partition(obj_ref::JuMP.ConstraintRef, _) = ()
get_indices_of_obj_in_partition(obj_ref::JuMP.VariableRef, _) = ()
get_indices_of_obj_in_partition(obj_ref::Array{<:JuMP.VariableRef, N}, _) where N = ntuple(i -> Colon(), N)
get_indices_of_obj_in_partition(obj_ref::Array{<:JuMP.ConstraintRef, N}, _) where N = ntuple(i -> Colon(), N)

struct ConstraintDecomposition <: MOI.AbstractConstraintAttribute end
struct VariableDecomposition <: MOI.AbstractVariableAttribute end
struct DecompositionTree <: MOI.AbstractModelAttribute end

setannotation!(model, obj::JuMP.ConstraintRef, a) = MOI.set(model, ConstraintDecomposition(), obj, a)
setannotation!(model, obj::JuMP.VariableRef, a) = MOI.set(model, VariableDecomposition(), obj, a)

function MOI.set(dest::MOIU.UniversalFallback, attribute::ConstraintDecomposition, 
        ci::MOI.ConstraintIndex, annotation::Annotation)
    if !haskey(dest.conattr, attribute)
        dest.conattr[attribute] = Dict{MOI.ConstraintIndex, Tuple}()
    end
    dest.conattr[attribute][ci] = annotation
    return
end

function MOI.set(
    dest::MOIU.UniversalFallback, attribute::VariableDecomposition, 
    vi::MOI.VariableIndex, ann::Annotation
)
    if !haskey(dest.varattr, attribute)
        dest.varattr[attribute] = Dict{MOI.VariableIndex, Tuple}()
    end
    dest.varattr[attribute][vi] = ann
    return
end

function MOI.set(
    dest::MOIU.UniversalFallback, attribute::DecompositionTree, tree::Tree
)
    dest.modattr[attribute] = tree
    return
end

function MOI.get(
    dest::MOIU.UniversalFallback, attribute::ConstraintDecomposition,
    ci::MOI.ConstraintIndex
)
    conattr = get(dest.conattr, attribute, nothing)
    conattr === nothing && return nothing
    val = get(conattr, ci, nothing)
    return val
end

function MOI.get(
    dest::MOIU.UniversalFallback, attribute::VariableDecomposition,
    vi::MOI.VariableIndex
)
    varattr = get(dest.varattr, attribute, nothing)
    varattr === nothing && return nothing
    val = get(varattr, vi, nothing)
    return val
end

function MOI.get(dest::MOIU.UniversalFallback, attribute::DecompositionTree)
    modattr = get(dest.modattr, attribute, nothing)
    return modattr
end

function setannotations!(
    model::JuMP.Model, objref::AbstractArray, indices::Tuple, ann::Annotation
)
    if applicable(iterate, objref[indices...])
        for obj in objref[indices...]
            setannotation!(model, obj, ann)
        end
    else
        obj = objref[indices...]
        setannotation!(model, obj, ann)
    end
    return
end

function setannotations!(
    model::JuMP.Model, objref::AbstractArray, indices_set::Vector{Tuple}, 
    ann::Annotation
)
    for indices in indices_set
        obj = objref[indices...]
        setannotation!(model, obj, ann)
    end
    return
end

function setannotations!(
    model::JuMP.Model, objref::JuMP.ConstraintRef, _, ann::Annotation
)
    setannotation!(model, objref, ann)
    return
end

function setannotations!(
    model::JuMP.Model, objref::JuMP.VariableRef, _, ann::Annotation
)
    setannotation!(model, objref, ann)
    return
end

settree!(model::JuMP.Model, tree) = MOI.set(model, DecompositionTree(), tree)
