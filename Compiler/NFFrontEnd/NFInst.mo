/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-2014, Open Source Modelica Consortium (OSMC),
 * c/o Linköpings universitet, Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 LICENSE OR
 * THIS OSMC PUBLIC LICENSE (OSMC-PL) VERSION 1.2.
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES
 * RECIPIENT'S ACCEPTANCE OF THE OSMC PUBLIC LICENSE OR THE GPL VERSION 3,
 * ACCORDING TO RECIPIENTS CHOICE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from OSMC, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package NFInst
" file:        NFInst.mo
  package:     NFInst
  description: Instantiation

  New instantiation, enable with +d=newInst.
"

import Absyn;
import SCode;

import Builtin = NFBuiltin;
import Binding = NFBinding;
import NFComponent.Component;
import ComponentRef = NFComponentRef;
import Dimension = NFDimension;
import Expression = NFExpression;
import NFClass.Class;
import NFInstNode.InstNode;
import NFInstNode.InstNodeType;
import NFMod.Modifier;
import NFMod.ModifierScope;
import Operator = NFOperator;
import NFEquation.Equation;
import NFStatement.Statement;
import Type = NFType;
import Subscript = NFSubscript;

protected
import Array;
import Error;
import Flatten = NFFlatten;
import Global;
import InstUtil = NFInstUtil;
import List;
import Lookup = NFLookup;
import MetaModelica.Dangerous;
import NFExtend;
import NFImport;
import Typing = NFTyping;
import ExecStat.{execStat,execStatReset};
import SCodeDump;
import SCodeUtil;
import System;
import NFCall.Call;
import Absyn.Path;
import NFClassTree.ClassTree;
import NFSections.Sections;
import NFInstNode.CachedData;

public
function instClassInProgram
  "Instantiates a class given by its fully qualified path, with the result being
   a DAE."
  input Absyn.Path classPath;
  input SCode.Program program;
  output DAE.DAElist dae;
  output DAE.FunctionTree funcs;
protected
  InstNode top, cls, inst_cls;
  Component top_comp;
  InstNode top_comp_node;
  String name;
algorithm
  execStatReset();

  // Create a root node from the given top-level classes.
  top := makeTopNode(program);
  name := Absyn.pathString(classPath);

  // Look up the class to instantiate and mark it as the root class.
  cls := Lookup.lookupClassName(classPath, top, Absyn.dummyInfo);
  cls := InstNode.setNodeType(InstNodeType.ROOT_CLASS(), cls);

  // Instantiate the class.
  inst_cls := instantiate(cls);
  execStat("NFInst.instantiate("+ name +")");

  // Instantiate expressions (i.e. anything that can contains crefs, like
  // bindings, dimensions, etc). This is done as a separate step after
  // instantiation to make sure that lookup is able to find the correct nodes.
  instExpressions(inst_cls);
  execStat("NFInst.instExpressions("+ name +")");

  // Type the class.
  Typing.typeClass(inst_cls, name);

  // Flatten the class into a DAE.
  (dae, funcs) := Flatten.flatten(inst_cls, name);
end instClassInProgram;

function instantiate
  input output InstNode node;
  input Modifier modifier = Modifier.NOMOD();
  input InstNode parent = InstNode.EMPTY_NODE();
algorithm
  node := partialInstClass(node);
  node := expandClass(node);
  node := instClass(node, modifier, parent);
end instantiate;

function expand
  input output InstNode node;
algorithm
  node := partialInstClass(node);
  node := expandClass(node);
end expand;

function makeTopNode
  "Creates an instance node from the given list of top-level classes."
  input list<SCode.Element> topClasses;
  output InstNode topNode;
protected
  SCode.Element cls_elem;
  Class cls;
algorithm
  // Create a fake SCode.Element for the top scope, so we don't have to make the
  // definition in InstNode an option.
  cls_elem := SCode.CLASS("<top>", SCode.defaultPrefixes, SCode.NOT_ENCAPSULATED(),
    SCode.NOT_PARTIAL(), SCode.R_PACKAGE(),
    SCode.PARTS(topClasses, {}, {}, {}, {}, {}, {}, NONE()),
    SCode.COMMENT(NONE(), NONE()), Absyn.dummyInfo);

  // Make an InstNode for the top scope, to use as the parent of the top level elements.
  topNode := InstNode.newClass(cls_elem, InstNode.EMPTY_NODE(), InstNodeType.TOP_SCOPE());

  // Create a new class from the elements, and update the inst node with it.
  cls := Class.fromSCode(topClasses, topNode);
  // The class needs to be expanded to allow lookup in it. The top scope will
  // only contain classes, so we can do this instead of the whole expandClass.
  cls := Class.initExpandedClass(cls);
  topNode := InstNode.updateClass(cls, topNode);
end makeTopNode;

function partialInstClass
  input output InstNode node;
protected
  Class c;
algorithm
  () := match InstNode.getClass(node)
    case Class.NOT_INSTANTIATED()
      algorithm
        c := partialInstClass2(InstNode.definition(node), node);
        node := InstNode.updateClass(c, node);
      then
        ();

    else ();
  end match;
end partialInstClass;

function partialInstClass2
  input SCode.Element definition;
  input InstNode scope;
  output Class cls;
algorithm
  cls := match definition
    local
      SCode.ClassDef cdef;
      Type ty;

    // A long class definition, add it's elements to a new scope.
    case SCode.CLASS(classDef = cdef as SCode.PARTS())
      then Class.fromSCode(cdef.elementLst, scope);

    // An enumeration definition, add the literals to a new scope.
    case SCode.CLASS(classDef = cdef as SCode.ENUMERATION())
      algorithm
        ty := makeEnumerationType(cdef.enumLst, scope);
      then
        Class.fromEnumeration(cdef.enumLst, ty, scope);

//    case SCode.CLASS(classDef = SCode.CLASS_EXTENDS())
//      algorithm
//        // get the already existing classes with the same name
//        print(getInstanceName() + " got class extends: " + definition.name + "\n");
//      then
//        fail();

    else Class.PARTIAL_CLASS(NFClassTree.EMPTY, Modifier.NOMOD());
  end match;
end partialInstClass2;

function makeEnumerationType
  input list<SCode.Enum> literals;
  input InstNode scope;
  output Type ty;
protected
  list<String> lits;
  Absyn.Path path;
algorithm
  path := InstNode.scopePath(scope);
  lits := list(e.literal for e in literals);
  ty := Type.ENUMERATION(path, lits);
end makeEnumerationType;

function expandClass
  input output InstNode node;
algorithm
  node := match InstNode.getClass(node)
    case Class.PARTIAL_CLASS() then expandClass2(node);
    else node;
  end match;
end expandClass;

function expandClass2
  input output InstNode node;
protected
  SCode.Element def = InstNode.definition(node);
algorithm
  node := match def
    local
      Absyn.TypeSpec ty;
      SCode.Mod der_mod;
      SCode.Element ext;
      Class c;
      SCode.ClassDef cdef;
      list<SCode.Element> exts;
      array<InstNode> comps;
      Modifier mod;
      list<InstNode> ext_nodes;
      Option<InstNode> builtin_ext;
      Class.Prefixes prefs;
      InstNode ext_node;
      list<Dimension> dims;
      ClassTree tree;

    // A short class definition, e.g. class A = B.
    case SCode.CLASS(classDef = cdef as SCode.DERIVED(typeSpec = ty, modifications = der_mod))
      algorithm
        // Look up the class that's being derived from and expand it.
        ext_node := Lookup.lookupBaseClassName(Absyn.typeSpecPath(ty), InstNode.parent(node), def.info);
        ext_node := expand(ext_node);

        // Fetch the needed information from the class definition and construct a DERIVED_CLASS.
        prefs := instClassPrefixes(def);
        dims := list(Dimension.RAW_DIM(d) for d in cdef.attributes.arrayDims);
        mod := Class.getModifier(InstNode.getClass(node));
        c := Class.DERIVED_CLASS(ext_node, mod, dims, prefs, cdef.attributes.direction);
        node := InstNode.updateClass(c, node);
      then
        node;

    case SCode.CLASS(classDef = cdef as SCode.PARTS())
      algorithm
        c := InstNode.getClass(node);
        // Change the class to an empty expanded class, to avoid instantiation loops.
        c := Class.initExpandedClass(c);
        node := InstNode.updateClass(c, node);

        Class.EXPANDED_CLASS(elements = tree, modifier = mod) := c;
        builtin_ext := ClassTree.mapFoldExtends(tree, expandExtends, NONE());

        prefs := instClassPrefixes(def);

        if isSome(builtin_ext) then
          node := expandBuiltinExtends(builtin_ext, tree, node);
        else
          tree := ClassTree.expand(tree);
          c := Class.EXPANDED_CLASS(tree, mod, prefs);
          node := InstNode.updateClass(c, node);
        end if;
      then
        node;

//    case SCode.CLASS(classDef = cdef as SCode.CLASS_EXTENDS())
//      algorithm
//        // get the already existing classes with the same name
//        print(getInstanceName() + " got class extends: " + def.name + "\n");
//      then
//        fail();

    else
      algorithm
        assert(false, getInstanceName() + " got unknown class");
      then
        fail();

  end match;
end expandClass2;

function instClassPrefixes
  input SCode.Element cls;
  output Class.Prefixes prefixes;
protected
  SCode.Prefixes prefs;
algorithm
  prefixes := match cls
    case SCode.CLASS(
        encapsulatedPrefix = SCode.Encapsulated.NOT_ENCAPSULATED(),
        partialPrefix = SCode.Partial.NOT_PARTIAL(),
        prefixes = SCode.Prefixes.PREFIXES(
          visibility = SCode.Visibility.PUBLIC(),
          finalPrefix = SCode.Final.NOT_FINAL(),
          innerOuter = Absyn.InnerOuter.NOT_INNER_OUTER(),
          replaceablePrefix = SCode.NOT_REPLACEABLE()))
      then Class.Prefixes.DEFAULT();

    case SCode.CLASS(prefixes = prefs)
      then Class.Prefixes.PREFIXES(
        cls.encapsulatedPrefix,
        cls.partialPrefix,
        prefs.visibility,
        prefs.finalPrefix,
        prefs.innerOuter,
        prefs.replaceablePrefix);

  end match;
end instClassPrefixes;

function expandExtends
  input output InstNode ext;
  input output Option<InstNode> builtinExt = NONE();
protected
  SCode.Element def;
  Absyn.Path base_path;
  InstNode scope, base_node;
  SCode.Visibility vis;
  SCode.Mod smod;
  Option<SCode.Annotation> ann;
  SourceInfo info;
algorithm
  def as SCode.Element.EXTENDS(base_path, vis, smod, ann, info) := InstNode.definition(ext);

  // Look up the base class and expand it.
  scope := InstNode.parent(ext);
  base_node := Lookup.lookupBaseClassName(base_path, scope, info);
  checkExtendsLoop(base_node, base_path, info);
  checkReplaceableBaseClass(base_node, base_path, info);
  base_node := expand(base_node);

  ext := InstNode.setNodeType(InstNodeType.BASE_CLASS(scope, def), base_node);

  // If the extended class is a builtin class, like Real or any type derived
  // from Real, then return it so we can handle it properly in expandClass.
  // We don't care if builtinExt is already SOME, since that's not legal and
  // will be caught by expandBuiltinExtends.
  if Class.isBuiltin(InstNode.getClass(base_node)) then
    builtinExt := SOME(ext);
  end if;
end expandExtends;

function checkExtendsLoop
  "Gives an error if a base node is in the process of being expanded itself,
   since that means we have an extends loop in the model."
  input InstNode node;
  input Absyn.Path path;
  input SourceInfo info;
algorithm
  () := match InstNode.getClass(node)
    // expand begins by changing the class to an EXPANDED_CLASS, but keeps the
    // class tree. So finding a PARTIAL_TREE here means the class is in the
    // process of being expanded.
    case Class.EXPANDED_CLASS(elements = ClassTree.PARTIAL_TREE())
      algorithm
        Error.addSourceMessage(Error.EXTENDS_LOOP,
          {Absyn.pathString(path)}, info);
      then
        fail();

    else ();
  end match;
end checkExtendsLoop;

function checkReplaceableBaseClass
  "Checks that all parts of a name used as a base class are transitively
   non-replaceable."
  input InstNode baseClass;
  input Absyn.Path basePath;
  input SourceInfo info;
protected
  Integer count;
  InstNode node = baseClass;
algorithm
  count := Absyn.pathPartCount(basePath);

  for i in 1:count loop
    if isReplaceable(node) then
      Error.addSourceMessage(Error.REPLACEABLE_BASE_CLASS,
        {InstNode.name(node)}, info);
      fail();
    end if;

    node := InstNode.parent(node);
  end for;
end checkReplaceableBaseClass;

function isReplaceable
  input InstNode node;
  output Boolean isReplaceable = false;
algorithm

end isReplaceable;

function expandBuiltinExtends
  "This function handles the case where a class extends from a builtin type,
   like Real or some type derived from Real."
  input Option<InstNode> builtinExtends;
  input ClassTree scope;
  input output InstNode node;
protected
  InstNode builtin_ext;
  Class c;
  ClassTree tree;
algorithm
  // Fetch the class of the builtin type.
  SOME(builtin_ext) := builtinExtends;
  c := InstNode.getClass(builtin_ext);

  tree := Class.classTree(InstNode.getClass(node));

  // A class extending from a builtin type may not have other components or baseclasses.
  if ClassTree.componentCount(tree) > 0 or ClassTree.extendsCount(tree) > 1 then
    // ***TODO***: Find the invalid element and use its info to make the error
    //             message more accurate.
    Error.addSourceMessage(Error.BUILTIN_EXTENDS_INVALID_ELEMENTS,
      {InstNode.name(builtin_ext)}, InstNode.info(node));
    fail();
  end if;

  // Replace the class we're expanding with the builtin type.
  node := InstNode.updateClass(c, node);
end expandBuiltinExtends;

function instClass
  input output InstNode node;
  input Modifier modifier;
  input InstNode parent = InstNode.EMPTY_NODE();
protected
  InstNode par;
  Class cls, inst_cls;
  ClassTree cls_tree;
  Modifier cls_mod, mod;
  list<Modifier> type_attr;
algorithm
  cls := InstNode.getClass(node);
  cls_mod := Class.getModifier(cls);
  cls_mod := Modifier.merge(modifier, cls_mod);

  cls_mod := match cls_mod
    case Modifier.REDECLARE()
      algorithm
        node := expand(cls_mod.element);
        cls := InstNode.getClass(node);
      then
        Class.getModifier(cls);

    else cls_mod;
  end match;

  () := match cls
    case Class.EXPANDED_CLASS()
      algorithm
        (node, par) := ClassTree.instantiate(node, parent);
        Class.EXPANDED_CLASS(elements = cls_tree) := InstNode.getClass(node);

        // Fetch modification on the class definition.
        mod := Modifier.fromElement(InstNode.definition(node), InstNode.parent(node));
        // Merge with any outer modifications.
        mod := Modifier.merge(cls_mod, mod);

        // Apply the modifiers of extends nodes.
        ClassTree.mapExtends(cls_tree, function modifyExtends(scope = node));

        // Apply modifier in this scope.
        applyModifier(mod, cls_tree, InstNode.name(node));

        // Instantiate the extends nodes.
        ClassTree.mapExtends(cls_tree, function instExtends(parent = par));

        // Instantiate local components.
        ClassTree.applyLocalComponents(cls_tree,
          function instComponent(parent = par, scope = node));
      then
        ();

    case Class.DERIVED_CLASS()
      algorithm
        mod := Modifier.fromElement(InstNode.definition(node), InstNode.parent(node));
        mod := Modifier.merge(cls_mod, mod);
        node := instClass(cls.baseClass, mod, parent);
      then
        ();

    case Class.PARTIAL_BUILTIN()
      algorithm
        mod := Modifier.fromElement(InstNode.definition(node), InstNode.parent(node));
        mod := Modifier.merge(cls_mod, mod);

        type_attr := Modifier.toList(mod);
        inst_cls := Class.INSTANCED_BUILTIN(cls.ty, cls.elements, type_attr);

        node := InstNode.replaceClass(inst_cls, node);
      then
        ();

    else ();
  end match;
end instClass;

function instPackage
  input output InstNode node;
protected
  CachedData cache;
  InstNode inst;
algorithm
  cache := InstNode.cachedData(node);

  node := match cache
    case CachedData.PACKAGE() then cache.instance;

    case CachedData.NO_CACHE()
      algorithm
        inst := instantiate(node);
        instExpressions(inst);
        InstNode.setCachedData(CachedData.PACKAGE(inst), node);
      then
        inst;

    else
      algorithm
        assert(false, getInstanceName() + " got invalid instance cache");
      then
        fail();

  end match;
end instPackage;

function instImport
  input Absyn.Import imp;
  input InstNode scope;
  input SourceInfo info;
  input output list<InstNode> elements = {};
algorithm
  elements := match imp
    local
      InstNode node;
      ClassTree tree;

    case Absyn.NAMED_IMPORT()
      algorithm
        node := Lookup.lookupImport(imp.path, scope, info);
        node := InstNode.rename(imp.name, node);
      then
        node :: elements;

    case Absyn.QUAL_IMPORT()
      algorithm
        node := Lookup.lookupImport(imp.path, scope, info);
      then
        node :: elements;

    case Absyn.UNQUAL_IMPORT()
      algorithm
        node := Lookup.lookupImport(imp.path, scope, info);
        node := instPackage(node);
        tree := Class.classTree(InstNode.getClass(node));

        () := match tree
          case ClassTree.FLAT_TREE()
            algorithm
              elements := listAppend(arrayList(tree.classes), elements);
              elements := listAppend(arrayList(tree.components), elements);
            then
              ();

          else
            algorithm
              assert(false, getInstanceName() + " got invalid class tree");
            then
              ();
        end match;
      then
        elements;

  end match;
end instImport;

function modifyExtends
  input output InstNode extendsNode;
  input InstNode scope;
protected
  SCode.Element elem;
  Absyn.Path basepath;
  SCode.Mod smod;
  Modifier ext_mod;
  InstNode ext_node;
  SourceInfo info;
  ClassTree cls_tree;
algorithm
  cls_tree := Class.classTree(InstNode.getClass(extendsNode));
  ClassTree.mapExtends(cls_tree, function modifyExtends(scope = scope));

  InstNodeType.BASE_CLASS(definition = elem) := InstNode.nodeType(extendsNode);
  SCode.EXTENDS(baseClassPath = basepath, modifications = smod, info = info) := elem;

  // TODO: Lookup the base class and merge its modifier.
  //ext_node := Lookup.lookupBaseClassName(basepath, scope, info);

  ext_mod := Modifier.fromElement(elem, scope);
  applyModifier(ext_mod, cls_tree, InstNode.name(extendsNode));
end modifyExtends;

function instExtends
  input output InstNode node;
  input InstNode parent;
protected
  Class cls;
  ClassTree cls_tree;
algorithm
  cls := InstNode.getClass(node);

  () := match cls
    case Class.EXPANDED_CLASS(elements = cls_tree)
      algorithm
        ClassTree.mapExtends(cls_tree, function instExtends(parent = parent));

        // TODO: Propagate visibility of extends clause to components.
        ClassTree.applyLocalComponents(cls_tree,
          function instComponent(parent = node, scope = node));
      then
        ();

    else ();
  end match;
end instExtends;

function applyModifier
  input Modifier modifier;
  input ClassTree cls;
  input String clsName;
protected
  list<Modifier> mods;
  InstNode node;
  Component comp;
algorithm
  mods := Modifier.toList(modifier);

  if listEmpty(mods) then
    return;
  end if;

  for mod in mods loop
    try
      node := ClassTree.lookupElement(Modifier.name(mod), cls);
    else
      Error.addSourceMessage(Error.MISSING_MODIFIED_ELEMENT,
        {Modifier.name(mod), clsName}, Modifier.info(mod));
      fail();
    end try;

    if InstNode.isComponent(node) then
      InstNode.componentApply(node, Component.mergeModifier, mod);
    else
      partialInstClass(node);
      InstNode.classApply(node, Class.mergeModifier, mod);
    end if;
  end for;
end applyModifier;

function instComponent
  input InstNode node   "The component node to instantiate";
  input InstNode parent "The parent of the component, usually another component";
  input InstNode scope  "The class scope containing the component";
protected
  Component comp, inst_comp;
  SCode.Element def;
  InstNode scp, cls;
  Modifier mod, comp_mod;
  Binding binding;
  DAE.Type ty;
  Component.Attributes attr;
  list<Dimension> dims;
algorithm
  def := InstNode.definition(node);
  comp := InstNode.component(node);
  mod := Component.getModifier(comp);

  () := match (mod, comp, def)
    case (Modifier.REDECLARE(), _, _)
      algorithm
        comp := InstNode.component(mod.element);
        InstNode.updateComponent(comp, node);
        instComponent(node, parent, InstNode.parent(mod.element));
      then
        ();

    case (_, Component.COMPONENT_DEF(), SCode.COMPONENT())
      algorithm
        comp_mod := Modifier.fromElement(def, parent);
        comp_mod := Modifier.merge(comp.modifier, comp_mod);

        dims := list(Dimension.RAW_DIM(d) for d in def.attributes.arrayDims);
        Modifier.checkEach(comp_mod, listEmpty(dims), InstNode.name(node));
        comp_mod := Modifier.propagate(comp_mod, listLength(dims));

        // Instantiate the type of the component.
        cls := instTypeSpec(def.typeSpec, comp_mod, scope, node, def.info);

        // Instantiate attributes and create the untyped components.
        attr := instComponentAttributes(def.attributes, def.prefixes);
        binding := Modifier.binding(comp_mod);
        inst_comp := Component.UNTYPED_COMPONENT(cls, listArray(dims), binding, attr, def.info);
        InstNode.updateComponent(inst_comp, node);
      then
        ();

    else ();
  end match;
end instComponent;

function instComponentAttributes
  input SCode.Attributes compAttr;
  input SCode.Prefixes compPrefs;
  output Component.Attributes attributes;
protected
  DAE.ConnectorType cty;
  DAE.VarParallelism par;
  DAE.VarKind var;
  DAE.VarDirection dir;
  DAE.VarInnerOuter io;
  DAE.VarVisibility vis;
algorithm
  cty := InstUtil.translateConnectorType(compAttr.connectorType);
  par := InstUtil.translateParallelism(compAttr.parallelism);
  var := InstUtil.translateVariability(compAttr.variability);
  dir := InstUtil.translateDirection(compAttr.direction);
  io  := InstUtil.translateInnerOuter(compPrefs.innerOuter);
  vis := InstUtil.translateVisibility(compPrefs.visibility);
  attributes := Component.Attributes.ATTRIBUTES(cty, par, var, dir, io, vis);
end instComponentAttributes;

function instTypeSpec
  input Absyn.TypeSpec typeSpec;
  input Modifier modifier;
  input InstNode scope;
  input InstNode parent;
  input SourceInfo info;
  output InstNode node;
algorithm
  node := match typeSpec
    case Absyn.TPATH()
      algorithm
        node := Lookup.lookupClassName(typeSpec.path, scope, info);
        node := instantiate(node, modifier, parent);
      then
        node;

    case Absyn.TCOMPLEX()
      algorithm
        print("NFInst.instTypeSpec: TCOMPLEX not implemented.\n");
      then
        fail();

  end match;
end instTypeSpec;

function instDimension
  input output Dimension dimension;
  input InstNode scope;
  input SourceInfo info;
algorithm
  dimension := match dimension
    local
      Absyn.Subscript dim;
      Expression exp;

    case Dimension.RAW_DIM(dim = dim)
      then
        match dim
          case Absyn.NOSUB() then Dimension.UNKNOWN();
          case Absyn.SUBSCRIPT()
            algorithm
              exp := instExp(dim.subscript, scope, info, true);
            then
              Dimension.UNTYPED(exp, false);
        end match;

    else dimension;
  end match;
end instDimension;

function instExpressions
  input InstNode node;
  input InstNode scope = node;
  input output Sections sections = Sections.EMPTY();
protected
  Class cls = InstNode.getClass(node), inst_cls;
  array<InstNode> local_comps;
  ClassTree cls_tree;
algorithm
  () := match cls
    case Class.EXPANDED_CLASS(elements = cls_tree)
      algorithm
        // Instantiate expressions in the extends nodes.
        sections := ClassTree.foldExtends(cls_tree,
          function instExpressions(scope = node), sections);

        // Instantiate expressions in the local components.
        ClassTree.applyLocalComponents(cls_tree,
          function instComponentExpressions(scope = scope));

        // Flatten the class tree so we don't need to deal with extends anymore.
        cls.elements := ClassTree.flatten(cls_tree);
        InstNode.updateClass(cls, node);

        // Instantiate local equation/algorithm sections.
        sections := instSections(node, scope, sections);
        InstNode.classApply(node, Class.setSections, sections);
      then
        ();

    case Class.INSTANCED_BUILTIN()
      algorithm
        cls.attributes := list(instBuiltinAttribute(a) for a in cls.attributes);
        InstNode.updateClass(cls, node);
      then
        ();

    else
      algorithm
        assert(false, getInstanceName() + " got invalid class");
      then
        fail();

  end match;
end instExpressions;

function instBuiltinAttribute
  input output Modifier attribute;
algorithm
  () := match attribute
    case Modifier.MODIFIER()
      algorithm
        attribute.binding := instBinding(attribute.binding);
      then
        ();
  end match;
end instBuiltinAttribute;

function instComponentExpressions
  input InstNode component;
  input InstNode scope;
protected
  Component c = InstNode.component(component);
  array<Dimension> dims;
algorithm
  () := match c
    case Component.UNTYPED_COMPONENT(dimensions = dims)
      algorithm
        c.binding := instBinding(c.binding);

        for i in 1:arrayLength(dims) loop
          dims[i] := instDimension(dims[i], scope, c.info);
        end for;

        instExpressions(c.classInst, component);
        InstNode.updateComponent(c, component);
      then
        ();

    else
      algorithm
        assert(false, getInstanceName() + " got invalid component");
      then
        fail();

  end match;
end instComponentExpressions;

function instBinding
  input output Binding binding;
  input Boolean allowTypename = false;
algorithm
  binding := match binding
    local
      Expression bind_exp;

    case Binding.RAW_BINDING()
      algorithm
        bind_exp := instExp(binding.bindingExp, binding.scope, binding.info, allowTypename);
      then
        Binding.UNTYPED_BINDING(bind_exp, false, binding.scope, binding.propagatedDims, binding.info);

    else binding;
  end match;
end instBinding;

function instExpOpt
  input Option<Absyn.Exp> absynExp;
  input InstNode scope;
  input SourceInfo info;
  output Option<Expression> exp;
algorithm
  exp := match absynExp
    local
      Absyn.Exp aexp;

    case NONE() then NONE();
    case SOME(aexp) then SOME(instExp(aexp, scope, info));

  end match;
end instExpOpt;

function instExp
  input Absyn.Exp absynExp;
  input InstNode scope;
  input SourceInfo info;
  input Boolean allowTypename = false;
  output Expression exp;
algorithm
  exp := match absynExp
    local
      Expression e1, e2, e3;
      Option<Expression> oe;
      Operator op;
      list<Expression> expl;

    case Absyn.Exp.INTEGER() then Expression.INTEGER(absynExp.value);
    case Absyn.Exp.REAL() then Expression.REAL(stringReal(absynExp.value));
    case Absyn.Exp.STRING() then Expression.STRING(absynExp.value);
    case Absyn.Exp.BOOL() then Expression.BOOLEAN(absynExp.value);

    case Absyn.Exp.CREF()
      then instCref(absynExp.componentRef, scope, info, allowTypename);

    case Absyn.Exp.ARRAY()
      algorithm
        expl := list(instExp(e, scope, info) for e in absynExp.arrayExp);
      then
        Expression.ARRAY(Type.UNKNOWN(), expl);

    case Absyn.Exp.MATRIX()
      algorithm
        expl := list(Expression.ARRAY(
            Type.UNKNOWN(), list(instExp(e, scope, info) for e in el))
          for el in absynExp.matrix);
      then
        Expression.ARRAY(Type.UNKNOWN(), expl);

    case Absyn.Exp.RANGE()
      algorithm
        e1 := instExp(absynExp.start, scope, info);
        oe := instExpOpt(absynExp.step, scope, info);
        e3 := instExp(absynExp.stop, scope, info);
      then
        Expression.RANGE(Type.UNKNOWN(), e1, oe, e3);

    case Absyn.Exp.BINARY()
      algorithm
        e1 := instExp(absynExp.exp1, scope, info);
        e2 := instExp(absynExp.exp2, scope, info);
        op := Operator.fromAbsyn(absynExp.op);
      then
        Expression.BINARY(e1, op, e2);

    case Absyn.Exp.UNARY()
      algorithm
        e1 := instExp(absynExp.exp, scope, info);
        op := Operator.fromAbsyn(absynExp.op);
      then
        Expression.UNARY(op, e1);

    case Absyn.Exp.LBINARY()
      algorithm
        e1 := instExp(absynExp.exp1, scope, info);
        e2 := instExp(absynExp.exp2, scope, info);
        op := Operator.fromAbsyn(absynExp.op);
      then
        Expression.LBINARY(e1, op, e2);

    case Absyn.Exp.LUNARY()
      algorithm
        e1 := instExp(absynExp.exp, scope, info);
        op := Operator.fromAbsyn(absynExp.op);
      then
        Expression.LUNARY(op, e1);

    case Absyn.Exp.RELATION()
      algorithm
        e1 := instExp(absynExp.exp1, scope, info);
        e2 := instExp(absynExp.exp2, scope, info);
        op := Operator.fromAbsyn(absynExp.op);
      then
        Expression.RELATION(e1, op, e2);

    case Absyn.Exp.IFEXP()
      algorithm
        e3 := instExp(absynExp.elseBranch, scope, info);

        for branch in listReverse(absynExp.elseIfBranch) loop
          e1 := instExp(Util.tuple21(branch), scope, info);
          e2 := instExp(Util.tuple22(branch), scope, info);
          e3 := Expression.IF(e1, e2, e3);
        end for;

        e1 := instExp(absynExp.ifExp, scope, info);
        e2 := instExp(absynExp.trueBranch, scope, info);
      then
        Expression.IF(e1, e2, e3);

    case Absyn.Exp.CALL()
      then Call.instantiate(absynExp.function_, absynExp.functionArgs, scope, info);

    case Absyn.Exp.END() then Expression.END();

    else
      algorithm
        assert(false, getInstanceName() + " got unknown expression");
      then
        fail();

  end match;
end instExp;

function instCref
  input Absyn.ComponentRef absynCref;
  input InstNode scope;
  input SourceInfo info;
  input Boolean allowTypename = false "Allows crefs referring to typenames if true.";
  output Expression cref;

  import NFComponentRef.Origin;
protected
  InstNode node;
  list<InstNode> nodes;
  ComponentRef cr;
  InstNode found_scope;
  Type ty;
  Component comp;
algorithm
  (node, nodes, found_scope) := Lookup.lookupComponent(absynCref, scope, info, allowTypename);

  if InstNode.isComponent(node) then
    comp := InstNode.component(node);

    cref := match comp
      case Component.ITERATOR()
        then Expression.CREF(ComponentRef.fromNode(node, comp.ty, {}, Origin.ITERATOR));

      case Component.ENUM_LITERAL()
        then comp.literal;

      else
        algorithm
          cr := ComponentRef.fromNodeList(InstNode.scopeList(found_scope));
          cr := makeCref(absynCref, nodes, scope, info, cr);
        then
          Expression.CREF(cr);
    end match;
  else
    if allowTypename then
      ty := InstNode.getType(node);

      ty := match ty
        case Type.BOOLEAN() then Type.ARRAY(ty, {Dimension.BOOLEAN()});
        case Type.ENUMERATION() then Type.ARRAY(ty, {Dimension.ENUM(ty)});
      end match;

      cref := Expression.TYPENAME(ty);
    else
      cr := ComponentRef.fromNodeList(InstNode.scopeList(found_scope));
      cr := makeCref(absynCref, nodes, scope, info, cr);
      cref := Expression.CREF(cr);
    end if;
  end if;

end instCref;

function makeCref
  input Absyn.ComponentRef absynCref;
  input list<InstNode> nodes;
  input InstNode scope;
  input SourceInfo info;
  input ComponentRef accumCref = ComponentRef.EMPTY();
  output ComponentRef cref;

  import NFComponentRef.Origin;
algorithm
  cref := match (absynCref, nodes)
    local
      InstNode node;
      list<InstNode> rest_nodes;
      list<Subscript> subs;

    case (Absyn.ComponentRef.CREF_IDENT(), {node})
      algorithm
        subs := list(instSubscript(s, scope, info) for s in absynCref.subscripts);
      then
        ComponentRef.CREF(node, subs, Type.UNKNOWN(), Origin.CREF, accumCref);

    case (Absyn.ComponentRef.CREF_QUAL(), node :: rest_nodes)
      algorithm
        subs := list(instSubscript(s, scope, info) for s in absynCref.subscripts);
        cref := ComponentRef.CREF(node, subs, Type.UNKNOWN(), Origin.CREF, accumCref);
      then
        makeCref(absynCref.componentRef, rest_nodes, scope, info, cref);

    case (Absyn.ComponentRef.CREF_FULLYQUALIFIED(), _)
      then makeCref(absynCref.componentRef, nodes, scope, info, accumCref);

    case (Absyn.ComponentRef.WILD(), _) then ComponentRef.WILD();
    case (Absyn.ComponentRef.ALLWILD(), _) then ComponentRef.WILD();

    else
      algorithm
        assert(false, getInstanceName() + " failed");
      then
        fail();

  end match;
end makeCref;

function instSubscript
  input Absyn.Subscript absynSub;
  input InstNode scope;
  input SourceInfo info;
  output Subscript subscript;
protected
  Expression exp;
algorithm
  subscript := match absynSub
    case Absyn.Subscript.NOSUB() then Subscript.WHOLE();
    case Absyn.Subscript.SUBSCRIPT()
      algorithm
        exp := instExp(absynSub.subscript, scope, info);
      then
        Subscript.fromExp(exp);
  end match;
end instSubscript;

function instSections
  input InstNode node;
  input InstNode scope;
  input output Sections sections;
protected
  SCode.Element el = InstNode.definition(node);
  SCode.ClassDef def;
algorithm
  sections := match el
    case SCode.CLASS(classDef = SCode.PARTS())
      then instSections2(el.classDef, scope, sections);

    case SCode.CLASS(classDef = SCode.CLASS_EXTENDS(composition = def as SCode.PARTS()))
      then instSections2(def, scope, sections);

    else sections;
  end match;
end instSections;

function instSections2
  input SCode.ClassDef parts;
  input InstNode scope;
  input output Sections sections;
algorithm
  sections := match parts
    local
      list<Equation> eq, ieq;
      list<list<Statement>> alg, ialg;

    case SCode.PARTS()
      algorithm
        eq := instEquations(parts.normalEquationLst, scope);
        ieq := instEquations(parts.initialEquationLst, scope);
        alg := instAlgorithmSections(parts.normalAlgorithmLst, scope);
        ialg := instAlgorithmSections(parts.initialAlgorithmLst, scope);
      then
        Sections.join(Sections.new(eq, ieq, alg, ialg), sections);

  end match;
end instSections2;

function instEquations
  input list<SCode.Equation> scodeEql;
  input InstNode scope;
  output list<Equation> instEql;
algorithm
  instEql := list(instEquation(eq, scope) for eq in scodeEql);
end instEquations;

function instEquation
  input SCode.Equation scodeEq;
  input InstNode scope;
  output Equation instEq;
protected
  SCode.EEquation eq;
algorithm
  SCode.EQUATION(eEquation = eq) := scodeEq;
  instEq := instEEquation(eq, scope);
end instEquation;

function instEEquations
  input list<SCode.EEquation> scodeEql;
  input InstNode scope;
  output list<Equation> instEql;
algorithm
  instEql := list(instEEquation(eq, scope) for eq in scodeEql);
end instEEquations;

function instEEquation
  input SCode.EEquation scodeEq;
  input InstNode scope;
  output Equation instEq;
algorithm
  instEq := match scodeEq
    local
      Expression exp1, exp2, exp3;
      Option<Expression> oexp;
      list<Expression> expl;
      list<Equation> eql;
      list<tuple<Expression, list<Equation>>> branches;
      SourceInfo info;
      Binding binding;
      InstNode for_scope, iter;

    case SCode.EEquation.EQ_EQUALS(info = info)
      algorithm
        exp1 := instExp(scodeEq.expLeft, scope, info);
        exp2 := instExp(scodeEq.expRight, scope, info);
      then
        Equation.EQUALITY(exp1, exp2, Type.UNKNOWN(), info);

    case SCode.EEquation.EQ_CONNECT(info = info)
      algorithm
        exp1 := instCref(scodeEq.crefLeft, scope, info);
        exp2 := instCref(scodeEq.crefRight, scope, info);
      then
        Equation.CONNECT(exp1, Type.UNKNOWN(), exp2, Type.UNKNOWN(), info);

    case SCode.EEquation.EQ_FOR(info = info)
      algorithm
        binding := Binding.fromAbsyn(scodeEq.range, SCode.NOT_EACH(), 0, scope, info);
        binding := instBinding(binding, allowTypename = true);

        (for_scope, iter) := addIteratorToScope(scodeEq.index, binding, info, scope);
        eql := instEEquations(scodeEq.eEquationLst, for_scope);
      then
        Equation.FOR(iter, eql, info);

    case SCode.EEquation.EQ_IF(info = info)
      algorithm
        // Instantiate the conditions.
        expl := list(instExp(c, scope, info) for c in scodeEq.condition);

        // Instantiate each branch and pair it up with a condition.
        branches := {};
        for branch in scodeEq.thenBranch loop
          eql := instEEquations(branch, scope);
          exp1 :: expl := expl;
          branches := (exp1, eql) :: branches;
        end for;

        // Instantiate the else-branch, if there is one, and make it a branch
        // with condition true (so we only need a simple list of branches).
        if not listEmpty(scodeEq.elseBranch) then
          eql := instEEquations(scodeEq.elseBranch, scope);
          branches := (Expression.BOOLEAN(true), eql) :: branches;
        end if;
      then
        Equation.IF(listReverse(branches), info);

    case SCode.EEquation.EQ_WHEN(info = info)
      algorithm
        exp1 := instExp(scodeEq.condition, scope, info);
        eql := instEEquations(scodeEq.eEquationLst, scope);
        branches := {(exp1, eql)};

        for branch in scodeEq.elseBranches loop
          exp1 := instExp(Util.tuple21(branch), scope, info);
          eql := instEEquations(Util.tuple22(branch), scope);
          branches := (exp1, eql) :: branches;
        end for;
      then
        Equation.WHEN(branches, info);

    case SCode.EEquation.EQ_ASSERT(info = info)
      algorithm
        exp1 := instExp(scodeEq.condition, scope, info);
        exp2 := instExp(scodeEq.message, scope, info);
        exp3 := instExp(scodeEq.level, scope, info);
      then
        Equation.ASSERT(exp1, exp2, exp3, info);

    case SCode.EEquation.EQ_TERMINATE(info = info)
      algorithm
        exp1 := instExp(scodeEq.message, scope, info);
      then
        Equation.TERMINATE(exp1, info);

    case SCode.EEquation.EQ_REINIT(info = info)
      algorithm
        exp1 := instCref(scodeEq.cref, scope, info);
        exp2 := instExp(scodeEq.expReinit, scope, info);
      then
        Equation.REINIT(exp1, exp2, info);

    case SCode.EEquation.EQ_NORETCALL(info = info)
      algorithm
        exp1 := instExp(scodeEq.exp, scope, info);
      then
        Equation.NORETCALL(exp1, info);

    else
      algorithm
        assert(false, getInstanceName() + " got unknown equation");
      then
        fail();

  end match;
end instEEquation;

function instAlgorithmSections
  input list<SCode.AlgorithmSection> algorithmSections;
  input InstNode scope;
  output list<list<Statement>> statements;
algorithm
  statements := list(instAlgorithmSection(alg, scope) for alg in algorithmSections);
end instAlgorithmSections;

function instAlgorithmSection
  input SCode.AlgorithmSection algorithmSection;
  input InstNode scope;
  output list<Statement> statements;
algorithm
  statements := instStatements(algorithmSection.statements, scope);
end instAlgorithmSection;

function instStatements
  input list<SCode.Statement> scodeStmtl;
  input InstNode scope;
  output list<Statement> statements;
algorithm
  statements := list(instStatement(stmt, scope) for stmt in scodeStmtl);
end instStatements;

function instStatement
  input SCode.Statement scodeStmt;
  input InstNode scope;
  output Statement statement;
algorithm
  statement := match scodeStmt
    local
      Expression exp1, exp2, exp3;
      Option<Expression> oexp;
      list<Statement> stmtl;
      list<tuple<Expression, list<Statement>>> branches;
      SourceInfo info;
      Binding binding;
      InstNode for_scope, iter;

    case SCode.Statement.ALG_ASSIGN(info = info)
      algorithm
        exp1 := instExp(scodeStmt.assignComponent, scope, info);
        exp2 := instExp(scodeStmt.value, scope, info);
      then
        Statement.ASSIGNMENT(exp1, exp2, info);

    case SCode.Statement.ALG_FOR(info = info)
      algorithm
        binding := Binding.fromAbsyn(scodeStmt.range, SCode.NOT_EACH(), 0, scope, info);
        binding := instBinding(binding, allowTypename = true);

        (for_scope, iter) := addIteratorToScope(scodeStmt.index, binding, info, scope);
        stmtl := instStatements(scodeStmt.forBody, for_scope);
      then
        Statement.FOR(iter, stmtl, info);

    case SCode.Statement.ALG_IF(info = info)
      algorithm
        branches := {};
        for branch in (scodeStmt.boolExpr, scodeStmt.trueBranch) :: scodeStmt.elseIfBranch loop
          exp1 := instExp(Util.tuple21(branch), scope, info);
          stmtl := instStatements(Util.tuple22(branch), scope);
          branches := (exp1, stmtl) :: branches;
        end for;

        stmtl := instStatements(scodeStmt.elseBranch, scope);
        branches := listReverse((Expression.BOOLEAN(true), stmtl) :: branches);
      then
        Statement.IF(branches, info);

    case SCode.Statement.ALG_WHEN_A(info = info)
      algorithm
        branches := {};
        for branch in scodeStmt.branches loop
          exp1 := instExp(Util.tuple21(branch), scope, info);
          stmtl := instStatements(Util.tuple22(branch), scope);
          branches := (exp1, stmtl) :: branches;
        end for;
      then
        Statement.WHEN(listReverse(branches), info);

    case SCode.Statement.ALG_ASSERT(info = info)
      algorithm
        exp1 := instExp(scodeStmt.condition, scope, info);
        exp2 := instExp(scodeStmt.message, scope, info);
        exp3 := instExp(scodeStmt.level, scope, info);
      then
        Statement.ASSERT(exp1, exp2, exp3, info);

    case SCode.Statement.ALG_TERMINATE(info = info)
      algorithm
        exp1 := instExp(scodeStmt.message, scope, info);
      then
        Statement.TERMINATE(exp1, info);

    case SCode.Statement.ALG_REINIT(info = info)
      algorithm
        exp1 := instCref(scodeStmt.cref, scope, info);
        exp2 := instExp(scodeStmt.newValue, scope, info);
      then
        Statement.REINIT(exp1, exp2, info);

    case SCode.Statement.ALG_NORETCALL(info = info)
      algorithm
        exp1 := instExp(scodeStmt.exp, scope, info);
      then
        Statement.NORETCALL(exp1, info);

    case SCode.Statement.ALG_WHILE(info = info)
      algorithm
        exp1 := instExp(scodeStmt.boolExpr, scope, info);
        stmtl := instStatements(scodeStmt.whileBody, scope);
      then
        Statement.WHILE(exp1, stmtl, info);

    case SCode.Statement.ALG_RETURN() then Statement.RETURN(scodeStmt.info);
    case SCode.Statement.ALG_BREAK() then Statement.BREAK(scodeStmt.info);

    case SCode.Statement.ALG_FAILURE()
      algorithm
        stmtl := instStatements(scodeStmt.stmts, scope);
      then
        Statement.FAILURE(stmtl, scodeStmt.info);

    else
      algorithm
        assert(false, getInstanceName() + " got unknown statement");
      then
        fail();

  end match;
end instStatement;

function addIteratorToScope
  input String name;
  input Binding binding;
  input SourceInfo info;
  input output InstNode scope;
        output InstNode iterator;
protected
  Component iter_comp;
algorithm
  scope := InstNode.openImplicitScope(scope);
  iter_comp := Component.ITERATOR(Type.UNKNOWN(), binding);
  iterator := InstNode.fromComponent(name, iter_comp, scope);
  scope := InstNode.addIterator(iterator, scope);
end addIteratorToScope;

annotation(__OpenModelica_Interface="frontend");
end NFInst;
