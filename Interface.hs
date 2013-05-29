{-# LANGUAGE RecordWildCards, PolymorphicComponents, GADTs, TemplateHaskell #-}

module Interface where

import Control.Monad.ST
import qualified Data.Map as Map
import Data.Map (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import Control.Monad.State
import Control.Arrow
import Data.List as List
import Safe

import Control.Lens

import BddRecord

--types that appear in the backend syntax tree
data BAVar sp lp where
    StateVar :: sp -> Int -> BAVar sp lp
    LabelVar :: lp -> Int -> BAVar sp lp
    OutVar   :: lp -> Int -> BAVar sp lp
    deriving (Show, Eq, Ord)

--Operations that are given to the backend for compilation. 
data VarOps pdb v s u = VarOps {
    getVar  :: v -> StateT pdb (ST s) [DDNode s u],
    withTmp :: forall a. (DDNode s u -> StateT pdb (ST s) a) -> StateT pdb (ST s) a,
    allVars :: StateT pdb (ST s) [v]
}

--Generic utility functions
findWithDefaultM :: (Monad m, Ord k) => (v -> v') -> k -> Map k v -> m v' -> m v'
findWithDefaultM modF key theMap func = maybe func (return . modF) $ Map.lookup key theMap 

findWithDefaultProcessM :: (Monad m, Ord k) => (v -> v') -> k -> Map k v -> m v' -> (v -> m ()) -> m v'
findWithDefaultProcessM modF key theMap funcAbsent funcPresent = maybe funcAbsent func $ Map.lookup key theMap
    where
    func v = do
        funcPresent v
        return $ modF v

modifyM :: Monad m => (s -> m s) -> StateT s m ()
modifyM f = get >>= (lift . f) >>= put

unc :: ([a] -> [b] -> [c] -> [d] -> f) -> ([(a, b)], [(c, d)]) -> f
unc f (l1, l2) = f ul1 ul2 ul3 ul4
    where
    (ul1, ul2) = unzip l1
    (ul3, ul4) = unzip l2

--Variable type
type VarInfo s u = (DDNode s u, Int)
getNode = fst
getIdx = snd

--Symbol table
data SymbolInfo s u sp lp = SymbolInfo {
    --below maps are used for update function compilation and constructing
    _initVars           :: Map sp ([VarInfo s u], [VarInfo s u]),
    _stateVars          :: Map sp ([VarInfo s u], [VarInfo s u]),
    _labelVars          :: Map lp ([VarInfo s u], VarInfo s u),
    _outcomeVars        :: Map lp [VarInfo s u],
    --mappings from index to variable/predicate
    _stateRev           :: Map Int sp,
    _labelRev           :: Map Int (lp, Bool)
}
makeLenses ''SymbolInfo
initialSymbolTable = SymbolInfo Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty 

--Sections
data SectionInfo s u = SectionInfo {
    _trackedCube   :: DDNode s u,
    _trackedNodes  :: [DDNode s u],
    _trackedInds   :: [Int],
    _untrackedCube :: DDNode s u,
    _untrackedInds :: [Int],
    _labelCube     :: DDNode s u,
    _outcomeCube   :: DDNode s u,
    _nextCube      :: DDNode s u,
    _nextNodes     :: [DDNode s u]
}
makeLenses ''SectionInfo
initialSectionInfo Ops{..} = SectionInfo btrue [] [] btrue [] btrue btrue btrue []

derefSectionInfo :: Ops s u -> SectionInfo s u -> ST s ()
derefSectionInfo Ops{..} SectionInfo{..} = do
    deref _trackedCube
    deref _untrackedCube
    deref _labelCube
    deref _outcomeCube
    deref _nextCube

--Variable/predicate database
data DB s u sp lp = DB {
    _symbolTable :: SymbolInfo s u sp lp,
    _sections    :: SectionInfo s u,
    _avlOffset   :: Int
}
makeLenses ''DB
initialDB ops@Ops{..} = do
    let isi@SectionInfo{..} = initialSectionInfo ops
    let res = DB initialSymbolTable isi 0
    ref _trackedCube
    ref _untrackedCube
    ref _labelCube
    ref _outcomeCube
    ref _nextCube
    return res

--Generic variable allocations
alloc :: Ops s u -> StateT (DB s u sp lp) (ST s) (DDNode s u, Int)
alloc Ops{..} = do
    offset <- use avlOffset
    res    <- lift $ ithVar offset
    avlOffset += 1
    return (res, offset)

allocN :: Ops s u -> Int -> StateT (DB s u sp lp) (ST s) ([DDNode s u], [Int])
allocN Ops{..} size = do
    offset <- use avlOffset
    let indices = take size $ iterate (+1) offset
    res    <- lift $ mapM ithVar indices
    avlOffset += size
    return (res, indices)

allocNPair :: Ops s u -> Int -> StateT (DB s u sp lp) (ST s ) (([DDNode s u], [Int]), ([DDNode s u], [Int]))
allocNPair Ops{..} size = do
    offset <- use avlOffset
    let indices1 = take size $ iterate (+2) offset
    let indices2 = take size $ iterate (+2) (offset + 1)
    res1    <- lift $ mapM ithVar indices1
    res2    <- lift $ mapM ithVar indices2
    avlOffset += size * 2
    return ((res1, indices1), (res2, indices2))

--Do the variable allocation and symbol table tracking
addToCube :: Ops s u -> DDNode s u -> DDNode s u -> ST s (DDNode s u)
addToCube Ops{..} add cb = do
    res <- add .& cb
    deref cb
    return res

addToCubeDeref :: Ops s u -> DDNode s u -> DDNode s u -> ST s (DDNode s u)
addToCubeDeref Ops{..} add cb = do
    res <- add .& cb
    deref add
    deref cb
    return res

--initial state helpers
allocInitVar  :: (Ord sp) => Ops s u -> sp -> Int -> StateT (DB s u sp lp) (ST s) [DDNode s u]
allocInitVar ops@Ops{..} v size = do
    ((cn, ci), (nn, ni)) <- allocNPair ops size
    lift $ makeTreeNode (head ci) (2 * size) 4
    symbolTable . initVars %= Map.insert v (zip cn ci, zip nn ni)
    return cn

-- === goal helpers ===
data NewVars s u sp = NewVars {
    _allocatedStateVars  :: [(sp, [DDNode s u])]
}
makeLenses ''NewVars

data GoalState s u sp lp = GoalState {
    _nv :: NewVars s u sp,
    _db :: DB s u sp lp
}
makeLenses ''GoalState

liftToGoalState :: StateT (DB s u sp lp) (ST s) a -> StateT (GoalState s u sp lp) (ST s) a
liftToGoalState (StateT func) = StateT $ \st -> do
    (res, st') <- func (_db st) 
    return (res, GoalState (_nv st) st')

allocStateVar :: (Ord sp) => Ops s u -> sp -> Int -> StateT (GoalState s u sp lp) (ST s) [DDNode s u]
allocStateVar ops@Ops{..} name size = do
    ((cn, ci), (nn, ni)) <- liftToGoalState $ allocNPair ops size
    lift $ makeTreeNode (head ci) (2 * size) 4
    addVarToState ops name cn ci nn ni
    return cn

type Update a = a -> a

addStateVarSymbol :: (Ord sp) => sp -> [DDNode s u] -> [Int] -> [DDNode s u] -> [Int] -> Update (SymbolInfo s u sp lp)
addStateVarSymbol name vars idxs vars' idxs' = 
    stateVars %~ Map.insert name (zip vars idxs, zip vars' idxs') >>>
    stateRev  %~ flip (foldl func) idxs 
        where func theMap idx = Map.insert idx name theMap

addVarToStateSection :: Ops s u -> sp -> [DDNode s u] -> [Int] -> [DDNode s u] -> [Int] -> StateT (GoalState s u sp lp )(ST s) ()
addVarToStateSection ops@Ops{..} name varsCurrent idxsCurrent varsNext idxsNext = do
    db . sections . trackedNodes %= (varsCurrent ++)
    db . sections . trackedInds  %= (idxsCurrent ++)
    modifyM $ db . sections . trackedCube %%~ \c -> do
        cb <- nodesToCube varsCurrent
        addToCubeDeref ops c cb
    db . sections . nextNodes %= (varsNext ++)
    modifyM $ db . sections . nextCube %%~ \c -> do
        cb <- nodesToCube varsNext
        addToCubeDeref ops c cb
    nv . allocatedStateVars %= ((name, varsNext) :)

addVarToState :: (Ord sp) => Ops s u -> sp -> [DDNode s u] -> [Int] -> [DDNode s u] -> [Int] -> StateT (GoalState s u sp lp) (ST s) ()
addVarToState ops@Ops{..} name vars idxs vars' idxs' = do
    db . symbolTable %= addStateVarSymbol name vars idxs vars' idxs'
    addVarToStateSection ops name vars idxs vars' idxs'

-- === update helpers ===
allocUntrackedVar :: (Ord sp) => Ops s u -> sp -> Int -> StateT (DB s u sp lp) (ST s) [DDNode s u]
allocUntrackedVar ops@Ops{..} var size = do
    ((cn, ci), (nn, ni)) <- allocNPair ops size
    lift $ makeTreeNode (head ci) (2 * size) 4
    addVarToUntracked ops var cn ci nn ni
    return cn

addVarToUntracked  :: (Ord sp) => Ops s u -> sp -> [DDNode s u] -> [Int] -> [DDNode s u] -> [Int] -> StateT (DB s u sp lp) (ST s) ()
addVarToUntracked ops@Ops {..} name vars idxs vars' idxs' = do
    symbolTable %= addStateVarSymbol name vars idxs vars' idxs'
    sections . untrackedInds %= (idxs ++)
    modifyM $ sections . untrackedCube %%~ \c -> do
        cb <- nodesToCube vars
        addToCubeDeref ops c cb

allocLabelVar :: (Ord lp) => Ops s u -> lp -> Int -> StateT (DB s u sp lp) (ST s) [DDNode s u]
allocLabelVar ops@Ops{..} var size = do
    (vars, idxs) <- allocN ops size
    lift $ makeTreeNode (head idxs) size 4
    (en, enIdx) <- alloc ops
    --TODO include this in above group?
    symbolTable . labelVars %= Map.insert var ((zip vars idxs), (en, enIdx))
    symbolTable . labelRev  %= (
        flip (foldl (func vars idxs)) idxs >>>
        Map.insert enIdx (var, True)
        )
    modifyM $ sections . labelCube %%~ \c -> do
        cb <- nodesToCube vars
        r1 <- addToCubeDeref ops cb c
        addToCubeDeref ops en r1
    return vars
        where func vars idxs theMap idx = Map.insert idx (var, False) theMap

allocOutcomeVar :: (Ord lp) => Ops s u -> lp -> Int -> StateT (DB s u sp lp) (ST s) [DDNode s u]
allocOutcomeVar ops@Ops{..} name size = do
    (vars, idxs) <- allocN ops size
    lift $ makeTreeNode (head idxs) size 4
    symbolTable . outcomeVars %= Map.insert name (zip vars idxs)
    modifyM $ sections . outcomeCube %%~ \c -> do
        cb <- nodesToCube vars
        addToCubeDeref ops cb c
    return vars

-- === Variable promotion helpers ===
promoteUntrackedVar :: (Ord sp) => Ops s u -> sp -> StateT (GoalState s u sp lp) (ST s) ()
promoteUntrackedVar ops@Ops{..} var = do
    mp <- use $ db . symbolTable . stateVars
    let (c, n) = fromJustNote "promoteUntrackedVar" $ Map.lookup var mp
    let ((vars, idxs), (vars', idxs')) = (unzip c, unzip n)
    addVarToStateSection ops var vars idxs vars' idxs'
    db . sections . untrackedInds %= (\\ idxs)
    modifyM $ db . sections . untrackedCube %%~ \c -> do
        cb <- nodesToCube vars
        bexists cb c

promoteUntrackedVars :: (Ord sp) => Ops s u -> [sp] -> StateT (DB s u sp lp) (ST s) (NewVars s u sp)
promoteUntrackedVars ops vars = StateT $ \st -> do
    (_, GoalState{..}) <- runStateT (mapM_ (promoteUntrackedVar ops) vars) (GoalState (NewVars []) st)
    return (_nv, _db)

withTmp' :: Ops s u -> (DDNode s u -> StateT (DB s u sp lp) (ST s) a) -> StateT (DB s u sp lp) (ST s) a
withTmp' Ops{..} func = do
    ind <- use avlOffset
    var <- lift $ ithVar ind
    avlOffset += 1
    func var

--Construct the VarOps for compiling particular parts of the spec
goalOps :: Ord sp => Ops s u -> VarOps (GoalState s u sp lp) (BAVar sp lp) s u
goalOps ops = VarOps {withTmp = undefined {-withTmp' ops -}, ..}
    where
    getVar  (StateVar var size) = do
        SymbolInfo{..} <- use $ db . symbolTable
        findWithDefaultM (map getNode . fst) var _stateVars $ findWithDefaultProcessM (map getNode . fst) var _initVars (allocStateVar ops var size) (unc (addVarToState ops var))
    getVar  _ = error "Requested non-state variable when compiling goal section"

doGoal :: Ord sp => Ops s u -> (VarOps (GoalState s u sp lp) (BAVar sp lp) s u -> StateT (GoalState s u sp lp) (ST s) a) -> StateT (DB s u sp lp) (ST s) (a, NewVars s u sp)
doGoal ops complFunc = StateT $ \st -> do
    (res, GoalState{..}) <- runStateT (complFunc $ goalOps ops) (GoalState (NewVars []) st)
    return ((res, _nv), _db)

initOps :: Ord sp => Ops s u -> VarOps (DB s u sp lp) (BAVar sp lp) s u
initOps ops = VarOps {withTmp = withTmp' ops, ..}
    where
    getVar  (StateVar var size) = do
        SymbolInfo{..} <- use symbolTable
        findWithDefaultM (map getNode . fst) var _initVars (allocInitVar ops var size)
    getVar _ = error "Requested non-state variable when compiling init section"

doInit :: Ord sp => Ops s u -> (VarOps (DB s u sp lp) (BAVar sp lp) s u -> StateT (DB s u sp lp) (ST s) (DDNode s u)) -> StateT (DB s u sp lp) (ST s) (DDNode s u)
doInit ops complFunc = complFunc (initOps ops)

updateOps :: (Ord sp, Ord lp) => Ops s u -> VarOps (DB s u sp lp) (BAVar sp lp) s u
updateOps ops = VarOps {withTmp = withTmp' ops, ..}
    where
    getVar (StateVar var size) = do
        SymbolInfo{..} <- use symbolTable
        findWithDefaultM (map getNode . fst) var _stateVars $ findWithDefaultProcessM (map getNode . fst) var _initVars (allocUntrackedVar ops var size) (unc (addVarToUntracked ops var))
    getVar (LabelVar var size) = do
        SymbolInfo{..} <- use symbolTable
        findWithDefaultM (map getNode . fst) var _labelVars $ allocLabelVar ops var size
    getVar (OutVar var size) = do
        SymbolInfo{..} <- use symbolTable
        findWithDefaultM (map getNode) var _outcomeVars $ allocOutcomeVar ops var size

doUpdate :: (Ord sp, Ord lp) => Ops s u -> (VarOps (DB s u sp lp) (BAVar sp lp) s u -> StateT (DB s u sp lp) (ST s) (DDNode s u)) -> StateT (DB s u sp lp) (ST s) (DDNode s u)
doUpdate ops complFunc = complFunc (updateOps ops)

