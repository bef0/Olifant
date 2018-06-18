{-|
Module      : Olifant.Gen
Description : LLVM Code generator for Core

Generate LLVM IR from a fully typed Code

__No Symbol Table__

One of the interesting things I learned about the code generator is that a
symbol table is unnecessary.

As far as possible, we use an alternative strategy: a variable is a data
structure that contains all the information about itself. I find this approach
simpler. Each state of the compiler can augment and annotate more information
into the reference accordingly. A simple pass can be made even simpler without
getting into any of the StateT business.

Ref: http://www.aosabook.org/en/ghc.html § No Symbol Table
-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedStrings     #-}

module Olifant.Gen where

import Olifant.Compiler hiding (verify)
import Olifant.Core

import Prelude   (init, last)
import Protolude hiding (Type, concat, head, local, mod, moduleName, replace)

import Data.ByteString.Short (toShort)

import LLVM.AST
import LLVM.AST.Attribute
import LLVM.AST.CallingConvention
import LLVM.AST.Constant
import LLVM.AST.Global
import LLVM.AST.Type
import LLVM.Context               (withContext)
import LLVM.Module                (moduleLLVMAssembly, withModuleFromAST)
import LLVM.PassManager

-- | State of the complete program
data GenState = GenState
    { blocks  :: [BlockState] -- ^ Blocks, ordered and named
    , active  :: Text
    , counter :: Int          -- ^ Number of unnamed variables
    , mod     :: Module       -- ^ The LLVM Module pointer
    }

-- | State of a single block
--
-- A function definition contains a list of basic blocks, forming the Control
-- Flow Graph. Each basic block may optionally start with a label, contains a
-- list of instructions and ends with a terminator instruction such as a branch
-- or function return.
--
-- As of now, a function contains just one block.
data BlockState = BlockState
    { bname :: Text                     -- ^ Name of the block
    , stack :: [Named Instruction]      -- ^ List of operations
    , term  :: Maybe (Named Terminator) -- ^ Block terminator
    }

-- | Codegen monad is Olifant monad with state specialized to `GenState`
--
-- Errors are not expected to be recoverable. A valid type safe `Progn`
-- shouldn't raise an error and there is nothing much to do if the input is
-- wrong.
type Codegen a = Olifant GenState a

-- | Default `GenState`
genState :: GenState
genState = GenState { blocks = []
                    , active = "main"
                    , mod = defaultModule {moduleName = "calc"}
                    , counter = 0}

-- | Default `BlockState`
blockState :: Ref -> BlockState
blockState n = BlockState {bname = rname n, stack = [], term = Nothing}

-- * Manipulate `GenState`
--
-- | Add a global definition to the LLVM module
define :: Global -> Codegen ()
define g = do
    st <- get
    modl <- gets mod
    let defs = moduleDefinitions modl ++ [GlobalDefinition g]
    let mod' = modl {moduleDefinitions = defs}
    put $ st {mod = mod'}

-- | Declare an external function
--
-- I'm not sure if there is a better way to declare an external function than
-- defining a function with an empty block list and not without naming all
-- arguments `_`
declare :: Ref -> Codegen ()
declare (Ref n _ t Extern) = define f
  where
    f = functionDefaults { name = lname n
                         , parameters = (params t, False)
                         , returnType = native $ retT t
                         , basicBlocks = []}

    -- | Ty to list
    params :: Ty -> [Parameter]
    params t1 = case unsnoc $ flatT t1 of
      Just (ts, _) -> [Parameter (native ti) "_" [] | ti <- ts]
      Nothing      -> []

declare ref = err $ "Cannot extern " <> render ref

-- * Manipulate `BlockState`

-- | Get the current block
current :: Codegen BlockState
current = do
    block <- gets active
    bs <- gets (filter (\b -> bname b == block) . blocks)
    case bs of
        [b] -> return b
        _   -> err $ "Unable to find unique block " <> block <> " in "
               <> (show (map bname bs) :: Text)

-- | Replace a named block
replace :: BlockState -> Codegen ()
replace block = modify $ \s -> s {blocks = map r (blocks s) }
  where
    r :: BlockState -> BlockState
    r b
      | bname block == bname b = block
      | otherwise              = b

-- | Push a named instruction to the stack of the active block
push :: Named Instruction -> Codegen ()
push ins = do
    active' <- current
    replace $ active' {stack = stack active' ++ [ins]}

-- | Name an instruction and add to stack.
--
--  - Takes an expression of the form @Add 1 2@
--  - Gets a fresh name for it, @%2@
--  - Adds @%2 = Add 1 2@ to the stack
--  - Returns @%2@
--
unnamed :: Ty -> Instruction -> Codegen Operand
unnamed t ins = do
    new <- fresh
    push $ new := ins
    return $ LocalReference (native t) new
  where
    -- | Make a fresh unnamed variable; %4 or %5
    fresh :: Codegen Name
    fresh = do
        n <- gets counter
        modify $ \s -> s {counter = n + 1}
        return $ UnName . fromIntegral $ n

-- | Helper function to convert a Text -> ByteString -> ShortByteString -> Name
lname :: Text -> Name
lname = Name . toShort . toS

-- * Primitive wrappers
--
-- | Fetch a variable from memory
load :: Ty -> Operand -> Codegen Operand
load t var = unnamed t $ Load False var Nothing 0 []

-- | Create a simple block from a list of instructions and a terminator
basicBlock :: [Named Instruction] -> Named Terminator -> BasicBlock
basicBlock = BasicBlock (Name "entry")

-- | Return the last expression from a block
terminator :: Operand -> Codegen (Named Terminator)
terminator result = return $ Do $ Ret (Just result) []

-- * References
--
-- | Get an `Operand` operand from a reference
op :: Ref -> Codegen Operand
op   (Ref n _ t Local)  = return $ LocalReference (native t) $ lname n
op r@(Ref _ _ t Global) = externf r >>= load t
op r@(Ref _ _ t Extern) = externf r >>= load t

-- | Make an operand out of a global function;  @%f -> \@f@
--
externf :: Ref -> Codegen Operand
externf r@(Ref _ _ _ Local) =
    err $ "Attempt to externf local variable " <> render r
externf (Ref n _ t _) =
    return $ ConstantOperand $ GlobalReference (ptr $ native t) $ lname n

-- | Map from Olifant types to LLVM types
native :: Ty -> Type
native TUnit      = LLVM.AST.Type.void
native TInt       = i64
native TBool      = i1
native t =  FunctionType { argumentTypes = init tlist
                         , resultType = last tlist
                         , isVarArg = False}
  where
    tlist :: [Type]
    tlist = map native $ flatT t

-- | Generate code for a single expression
--
-- Return an operand, which is the LHS of the operand it just dealt with.
emit :: Core -> Codegen Operand

-- | Make a constant operand out of the constant
emit (Lit (Bool True)) = return $ ConstantOperand $ Int 1 1
emit (Lit (Bool False)) = return $ ConstantOperand $ Int 1 0
emit (Lit (Number n)) = return $ ConstantOperand $ Int 64 (toInteger n)

-- | Convert a reference into a local operand.
emit (Var ref) = op ref

-- | Apply function by name
emit (App ref@(Ref _ _ t scope) vals) = do
    callable <- externf ref

    when (scope == Extern) $ declare ref

    args' <- mapM emit vals
    let args'' = [(arg, []) | arg <- args'] :: [(Operand, [ParameterAttribute])]
    unnamed (retT t) $ Call Nothing C [] (Right callable) args'' [] []

-- | Top level lambda expression
emit (Lam r@(Ref n _i t Global) refs body) = do
    modify $ \s -> s {active = n, blocks = blockState r : blocks s}
    result <- mapM emit body
    term' <- terminator $ last result
    instructions <- stack <$> current
    let fn = functionDefaults {
          name = lname n
        , parameters = ([Parameter tipe nm [] | (tipe, nm) <- params], False)
        , returnType = native $ retT t
        , basicBlocks = [basicBlock instructions term']}
    define fn
    op r
  where
    params :: [(Type, Name)]
    params = [(native $ rty ref, lname $ rname ref) | ref <- refs]

-- | Apply something that is not a function
emit (Lam ref _ _) = err $ "Malformed lambda definition " <> render ref

-- | Add a constant global variable
emit (Let ref val) =
    emit val >>= \case
      res@(ConstantOperand value') -> do
        let t = case val of
              (Lit (Number _)) -> TInt;
              (Lit (Bool _))   -> TBool
              -- _                -> error "Non literal global variable"
        define $ global' t value'
        return res
      res@LocalReference{} ->
        return res
      res@MetadataOperand{} ->
        return res
  where
    global' :: Ty -> Constant -> Global
    global' t var = globalVariableDefaults {
        name = Name $ toShort $ toS $ rname ref
      , initializer = Just var
      , type' = native t
      }

-- * Code generation
--
-- | Make an LLVM module from a `Progn`
genm :: [Core] -> Either Error Module
genm prog = execM (run prog) genState >>= return . mod
  where
    -- | Step through the AST and _throw_ away the results
    run :: [Core] -> Codegen ()
    run cs = mapM_ emit $ init cs ++ [entry]
      where
        tt :: Ty
        tt = TInt :> TInt

        r :: Ref
        r = Ref "olifant" 0 tt Global

        entry :: Core
        entry = Lam r [] [last cs]

-- | Tweak passes of LLVM compiler
--
-- More info on opt passes:
--
--  - http://www.stephendiehl.com/llvm/#optimization-passes
--  - https://www.stackage.org/haddock/nightly-2017-06-28/llvm-hs-4.2.0/LLVM-PassManager.html
passes :: PassSetSpec
passes = defaultCuratedPassSetSpec {optLevel = Just 0}

-- | Generate native code with C++ FFI
toLLVM :: Module -> IO Text
toLLVM modl =
    withContext $ \context ->
        withModuleFromAST context modl $ \m ->
            -- Verification hides the AST and makes debugging extremely painful.
            -- verify m
            withPassManager passes $ \pm -> do
                _ <- runPassManager pm m
                toS <$> moduleLLVMAssembly m

-- | Return compiled LLVM IR
gen :: [Core] -> IO (Either Error Text)
gen ast =
    case genm ast of
        Left e     -> return $ Left e
        Right mod' -> toLLVM mod' >>= return . Right

err :: Text -> Codegen a
err = throwError . GenError
