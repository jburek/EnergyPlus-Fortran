MODULE HeatBalFiniteDiffManager

          ! Module containing the heat balance simulation routines

          ! MODULE INFORMATION:
          !       AUTHOR         Richard J. Liesen
          !       DATE WRITTEN   October 2003
          !       RE-ENGINEERED  Curtis Pedersen, 2006, Changed to Implicit FD calc for conduction,
          !                      and included enthalpy formulations for phase change materials.       
          !		 
          !                     2016, Jeremiah D. Crossett and Chad Coates of NRGsim Inc. added Material Property Phase Change Hysteresis Model based on the work 
          !                     of Ramprasad Chandrasekharan at Oklahoma State University.
 

          ! PURPOSE OF THIS MODULE:
          ! To encapsulate the data and algorithms required to
          ! manage the fiite difference heat balance simulation on the building.

          ! METHODOLOGY EMPLOYED:
          !

          ! REFERENCES:
          ! The MFD moisture balance method
          !  C. O. Pedersen, Enthalpy Formulation of conduction heat transfer problems
          !    involving latent heat, Simulation, Vol 18, No. 2, February 1972

          ! OTHER NOTES: 
		  ! 1)Begining line 1212 in the "!VE-2016 DEV" tag is under devolopment for new outputs.
          ! 2) Known bug when useing this module a known problem is when useing this module where temperatures are diffrent with no PCM objects. 


          !

          ! USE STATEMENTS:
          ! Use statements for data only modules
USE DataPrecisionGlobals
USE DataGlobals, Only:MaxNameLength,KelvinConv,outputfiledebug, NumOfTimeStepInHour,DisplayExtraWarnings,   &
                      TimeStepZone,Hourofday,TimeStep,OutputFileInits,BeginEnvrnFlag,DayofSim,WarmupFlag,SecInHour
USE DataInterfaces
USE DataMoistureBalance
USE DataHeatBalance, Only: Material, TotMaterials,MaxLayersInConstruct, QRadThermInAbs,Construct,      &
                           TotConstructs,UseCondFD,RegularMaterial,Air,Zone
USE DataHeatBalSurface, Only: NetLWRadToSurf, QRadSWOutAbs, QRadSWInAbs,QRadSWOutMvIns, TempSource, &
                         OpaqSurfInsFaceConductionFlux,OpaqSurfOutsideFaceConductionFlux,  &
                         OpaqSurfOutsideFaceConduction,QsrcHist,OpaqSurfInsFaceConduction,  &
                         QdotRadOutRepPerArea,MinSurfaceTempLimit,MaxSurfaceTempLimit,QdotRadNetSurfInRep,QRadNetSurfInReport
Use DataSurfaces, Only: Surface, TotSurfaces,Ground,SurfaceClass_Window, HeatTransferModel_CondFD
Use DataHeatBalFanSys, Only: Mat, ZoneAirHumRat, QHTRadSysSurf, QHWBaseboardSurf, QSteamBaseboardSurf, QElecBaseboardSurf
Use DataEnvironment, Only: SkyTemp, IsRain
USE Psychrometrics , Only:PsyRhFnTdbRhovLBnd0C,PsyWFnTdbRhPb,PsyHgAirFnWTdb
  ! Fan system Source/Sink heat value, and source/sink location temp from CondFD
USE DataHeatBAlFanSys,  ONLY: QRadSysSource,TCondFDSourceNode,QPVSysSource
USE HeatBalanceMovableInsulation,  ONLY : EvalOutsideMovableInsulation

IMPLICIT NONE   ! Enforce explicit typing of all variables

PRIVATE   !Make everything private except what is specifically Public

          ! MODULE PARAMETER DEFINITIONS:
REAL(r64), PARAMETER :: Lambda=2500000.0d0
REAL(r64), PARAMETER :: smalldiff=1.d-8  ! Used in places where "equality" tests should not be used.

INTEGER, PARAMETER :: CrankNicholsonSecondOrder = 1 ! original CondFD scheme.  semi implicit, second order in time
INTEGER, PARAMETER :: FullyImplicitFirstOrder  = 2 ! fully implicit scheme, first order in time.
CHARACTER(len=*), PARAMETER, DIMENSION(2) :: cCondFDSchemeType=  &
   (/'CrankNicholsonSecondOrder',  &
     'FullyImplicitFirstOrder  '/)

REAL(r64),PARAMETER :: TempInitValue = 23.0d0    ! Initialization value for Temperature
REAL(r64),PARAMETER :: RhovInitValue = 0.0115d0  ! Initialization value for Rhov
REAL(r64),PARAMETER :: EnthInitValue = 100.0d0   ! Initialization value for Enthalpy

          ! DERIVED TYPE DEFINITIONS:
TYPE, PUBLIC ::  ConstructionDataFD
  CHARACTER(len=MaxNameLength), ALLOCATABLE, DIMENSION(:) :: Name ! Name of construction
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: DelX                 !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TempStability
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: MoistStability

  Integer, ALLOCATABLE, DIMENSION(:) :: NodeNumPoint  !
!  INTEGER, ALLOCATABLE, DIMENSION(:) :: InterfaceNodeNums   ! Layer interfaces occur at these nodes

  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: Thickness
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: NodeXlocation ! sized to TotNode, contains X distance in m from outside face
  INTEGER :: TotNodes=0

  Integer :: DeltaTime=0

END TYPE ConstructionDataFD


TYPE, PUBLIC :: SurfaceDataFD
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: T             !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TOld          !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TT
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: Rhov          !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: RhovOld       !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: RhoT
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TD            !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TDT            !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TDTLast
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TDOld         !
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TDreport
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: RH
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: RHreport
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: EnthOld        ! Current node enthalpy
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: EnthNew        ! Node enthalpy at new time
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: EnthalpyH
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: EnthLast
  INTEGER                                 :: GSloopCounter = 0 ! count of inner loop iterations
  INTEGER                                 :: GSloopErrorCount = 0 ! recurring error counter
  REAL(r64)                               :: MaxNodeDelTemp = 0.0d0 ! largest change in node temps after calc
!VE START
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: TempLastStep 
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: Enthreport
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: EnthLastStep 
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: CpOld         !Node Enthalpy at old time
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: CpOld1        !Node Enthalpy at old time
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: CpOld2        !Node Enthalpy at old time for multiple material layer
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: Cp_node       !Node Enthalpy at old time
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: Cp1_node      !Node Enthalpy at old time for multiple material layer
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: Cp2_node      !Node Enthalpy at old time for multiple material layer 
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: PhaseChangeDeltaT      !Flag which determines which curve to use
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: PhaseChangeDeltaTOld   !Flag which determines which curve to use based on PhaseChangeDeltaT
                                                                    !(it stores the value of previous timesteps PhaseChangeDeltaT)  
                                                                    !(it stores the value of previous timesteps PhaseChangeDeltaT)
  INTEGER,      ALLOCATABLE, DIMENSION(:) :: PhaseChangeTransition
  INTEGER,      ALLOCATABLE, DIMENSION(:) :: PhaseChangeTransitionOld
  Integer,      ALLOCATABLE, DIMENSION(:) :: PhaseChangeState       !-2=liquid, -1=Melting, 0=Transition, 1=Freezing, 2=Crystallized                      
  Integer,      ALLOCATABLE, DIMENSION(:) :: PhaseChangeStateold    !-2=liquid, -1=Melting, 0=Transition, 1=Freezing, 2=Crystallized ! of previous timestep
  Integer,      ALLOCATABLE, DIMENSION(:) :: PhaseChangeStateoldold !-2=liquid, -1=Melting, 0=Transition, 1=Freezing, 2=Crystallized ! of timestep previous to previous timestep
  REAL(r64),    ALLOCATABLE, DIMENSION(:) :: PhaseChangeTemperatureReverse !Temperature at which the phase change curve reverses its direction  
  REAL(r64)         :: DeltaHM   ! Latent heat of Fusion Melting
  REAL(r64)         :: DeltaHF   ! Latent heat of Solidification Freezing
  REAL(r64)         :: DeltaH    ! ??????????????????Sum of Freezing and Melting??????????????
  REAL(r64)         :: EnthalpyM ! Melting Enthalpy at a particular temperature
  REAL(r64)         :: EnthalpyF ! Freezing Enthalpy at a particular temperature   
!VE END
END TYPE SurfaceDataFD

TYPE MaterialDataFD
  REAL(r64) :: tk1          =0.0d0  ! Temperature coefficient for thermal conductivity
  INTEGER   :: numTempEnth  = 0     ! number of Temperature/Enthalpy pairs
  INTEGER   :: numTempCond  = 0     ! number of Temperature/Conductivity pairs
  REAL(r64), ALLOCATABLE, DIMENSION(:,:)  :: TempEnth  ! Temperature enthalpy Function Pairs,
                                                       ! TempEnth(1,1)= first Temp, TempEnth(1,2) = First Enthalpy,
                                                       ! TempEnth(2,1) = secomd Temp, etc.
  REAL(r64), ALLOCATABLE, DIMENSION(:,:)  :: TempCond  ! Temperature thermal conductivity Function Pairs,
                                                       ! TempCond(1,1)= first Temp, Tempcond(1,2) = First conductivity,
                                                       ! TempEnth(2,1) = secomd Temp, etc.
END TYPE
          ! MODULE VARIABLE DECLARATIONS:
TYPE (ConstructionDataFD), PUBLIC, ALLOCATABLE, DIMENSION(:) :: ConstructFD
TYPE (SurfaceDataFD), PUBLIC,   ALLOCATABLE, DIMENSION(:) :: SurfaceFD
TYPE (MaterialDataFD), ALLOCATABLE, DIMENSION(:) :: MaterialFD

!REAL(r64) :: TFDout   =0.0d0
!REAL(r64) :: TFDin    =0.0d0
!REAL(r64) :: rhovFDout=0.0d0
!REAL(r64) :: rhovFDin =0.0d0
!REAL(r64) :: TDryout  =0.0d0
!REAL(r64) :: Tdryin   =0.0d0
!REAL(r64) :: RHOut    =0.0d0
!REAL(r64) :: RHIn     =0.0d0
REAL(r64), ALLOCATABLE, DIMENSION(:) :: SigmaR            ! Total Resistance of construction layers
REAL(r64), ALLOCATABLE, DIMENSION(:) :: SigmaC            ! Total Capacitance of construction layers

!REAL(r64), ALLOCATABLE, DIMENSION(:) :: WSurfIn           !Humidity Ratio of the inside surface for reporting
!REAL(r64), ALLOCATABLE, DIMENSION(:) :: QMassInFlux       !MassFlux on Surface for reporting
!REAL(r64), ALLOCATABLE, DIMENSION(:) :: QMassOutFlux      !MassFlux on Surface for reporting
REAL(r64), ALLOCATABLE, DIMENSION(:) :: QHeatInFlux       !HeatFlux on Surface for reporting
REAL(r64), ALLOCATABLE, DIMENSION(:) :: QHeatOutFlux      !HeatFlux on Surface for reporting
REAL(r64), ALLOCATABLE, DIMENSION(:) :: QFluxZoneToInSurf !sum of Heat flows at the surface to air interface,
!zone-side boundary conditions W/m2 before CR 8280 was not reported, but was calculated.
!REAL(r64), ALLOCATABLE, DIMENSION(:)   :: QFluxOutsideToOutSurf !sum of Heat flows at the surface to air interface, Out-side boundary conditions W/m2
!                                                           ! before CR 8280 was
!REAL(r64), ALLOCATABLE, DIMENSION(:)   :: QFluxInArrivSurfCond !conduction between surface node and first node into the surface (sensible)
!                                                           ! before CR 8280 was -- Qdryin    !HeatFlux on Surface for reporting for Sensible only
!REAL(r64), ALLOCATABLE, DIMENSION(:)   :: QFluxOutArrivSurfCond  !HeatFlux on Surface for reporting for Sensible only
!                                                                 ! before CR 8280 -- Qdryout         !HeatFlux on Surface for reporting for Sensible only


INTEGER   :: CondFDSchemeType = FullyImplicitFirstOrder   ! solution scheme for CondFD - default
REAL(r64) :: SpaceDescritConstant      = 3.d0             ! spatial descritization constant,
REAL(r64) :: MinTempLimit              = -100.d0          ! lower limit check, degree C
REAL(r64) :: MaxTempLimit              =  100.d0          ! upper limit check, degree C
!feb2012 INTEGER   :: MaxGSiter         = 200             ! maximum number of Gauss Seidel iterations
INTEGER   :: MaxGSiter                 = 30               ! maximum number of Gauss Seidel iterations
REAL(r64) :: fracTimeStepZone_Hour=0.0d0
LOGICAL   :: GetHBFiniteDiffInputFlag=.true.
INTEGER :: WarmupSurfTemp=0
          ! Subroutine Specifications for the Heat Balance Module
          ! Driver Routines
PUBLIC  ManageHeatBalFiniteDiff

          ! Initialization routines for module
PUBLIC  InitHeatBalFiniteDiff
PRIVATE GetCondFDInput

          ! Algorithms for the module
PRIVATE CalcHeatBalFiniteDiff
PRIVATE ExteriorBCEqns
PRIVATE InteriorBCEqns
PRIVATE terpld
PRIVATE InteriorNodeEqns
PRIVATE IntInterfaceNodeEqns
!VE START
PRIVATE SpecEnthalpy 
REAL(r64) :: TempTlowPCM= 0.0d0    !temperature at which phase change starts
REAL(r64) :: TempThighPCM= 0.0d0    !temperature at which phase change ends
REAL(r64) :: SpecHeatSolidPCM                     !specific heat of PCM in solid state
REAL(r64) :: SpecHeatLiquidPCM                    !specific heat of PCM in liquid state
REAL(r64) :: Tau1 
REAL(r64) :: Tau2 
REAL(r64) :: DeltaH 
REAL(r64) :: TcM 
REAL(r64) :: Tau1F 
REAL(r64) :: Tau2F 
REAL(r64) :: TcF 
REAL(r64) :: Tc
REAL(r64) :: TcOld 
INTEGER   :: HysteresisFlag= 1       ! 1 Dual curve Hysteresis model                     
!VE END 
          ! Reporting routines for module
PRIVATE ReportFiniteDiffInits

          ! Update Data Routine
PUBLIC  UpdateMoistureBalanceFD


CONTAINS

! MODULE SUBROUTINES:
!*************************************************************************
SUBROUTINE ManageHeatBalFiniteDiff(SurfNum,TempSurfInTmp,TempSurfOutTmp)
          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard Liesen
          !       DATE WRITTEN   May 2000
          !       MODIFIED       na
          !       RE-ENGINEERED  na

          ! PURPOSE OF THIS SUBROUTINE:
          ! This subroutine manages the moisture balance method.  It is called
          ! from the HeatBalanceManager at the time step level.
          ! This driver manages the calls to all of
          ! the other drivers and simulation algorithms.

          ! METHODOLOGY EMPLOYED:
          ! na

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:

  IMPLICIT NONE    ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS
  Integer,   Intent(In)    :: SurfNum
  REAL(r64), Intent(InOut) :: TempSurfInTmp       !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64), Intent(InOut) :: TempSurfOutTmp      !Outside Surface Temperature of each Heat Transfer Surface

          ! DERIVED TYPE DEFINITIONS
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:


          ! FLOW:

  ! Get the moisture balance input at the beginning of the simulation only
  IF (GetHBFiniteDiffInputFlag) THEN
      ! Obtains conduction FD related parameters from input file
    CALL GetCondFDInput
    GetHBFiniteDiffInputFlag=.false.
  ENDIF

  ! Condition is taken care of by calling routine:
  ! IF (Surface(SurfNum)%HeatTransSurf .and. Surface(SurfNum)%Class /= SurfaceClass_Window)

  ! Solve the zone heat & moisture balance using a finite difference solution
  CALL CalcHeatBalFiniteDiff(SurfNum,TempSurfInTmp,TempSurfOutTmp)

  RETURN

END SUBROUTINE ManageHeatBalFiniteDiff


! Get Input Section of the Module
!******************************************************************************
SUBROUTINE GetCondFDInput
          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Curtis Pedersen
          !       DATE WRITTEN   July 2006
          !       MODIFIED       Brent Griffith Mar 2011, user settings
          !
          !       RE-ENGINEERED  na

          ! PURPOSE OF THIS SUBROUTINE:
          ! This subroutine is the main driver for initializations for the variable property CondFD part of the
          ! MFD algorithm

          ! METHODOLOGY EMPLOYED:
          ! na

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
  USE DataIPShortCuts
  USE InputProcessor, ONLY: GetNumObjectsFound,GetObjectItem,FindItemInList
  USE DataHeatBalance, ONLY: MaxAllowedDelTempCondFD, CondFDRelaxFactor, CondFDRelaxFactorInput
  USE General, ONLY: RoundSigDigits

  IMPLICIT NONE    ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
          ! na
          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS
          ! na

          ! DERIVED TYPE DEFINITIONS
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
  INTEGER :: IOStat                             ! IO Status when calling get input subroutine
  CHARACTER(len=MaxNameLength),DIMENSION(3) &
          :: MaterialNames                      ! Number of Material Alpha names defined
  CHARACTER(len=MaxNameLength),DIMENSION(3)  :: ConstructionName ! Name of Construction with CondFDsimplified
  INTEGER :: MaterNum                           ! Counter to keep track of the material number
  INTEGER :: MaterialNumAlpha                   ! Number of material alpha names being passed
  INTEGER :: MaterialNumProp                    ! Number of material properties being passed
  REAL(r64), DIMENSION(40) :: MaterialProps !Temporary array to transfer material properties
  LOGICAL :: ErrorsFound = .false.              ! If errors detected in input
!  INTEGER :: CondFDMat                          ! Number of variable property CondFD materials in input
  INTEGER :: ConstructNumber                    ! Cconstruction with CondHBsimple to be overridden with CondHBdetailed

  INTEGER :: NumConstructionAlpha
  Integer :: Loop
  INTEGER :: NumAlphas
  INTEGER :: NumNumbers
  INTEGER :: propNum
  INTEGER :: pcount
  INTEGER :: pcMat
  INTEGER :: vcMat
  INTEGER :: inegptr
  LOGICAL :: nonInc

!VE START
  INTEGER :: CondFDMat    
  REAL(r64)  :: kt1
  REAL(r64), DIMENSION(10) :: PCMProps !Temporary array to transfer PCM properties 
  CHARACTER(len=MaxNameLength), DIMENSION(4) :: AlphaNameP
  INTEGER                                    :: NumAlphaP 
  INTEGER                                    :: NumObjectsP
!VE END
  ! user settings for numerical parameters
  cCurrentModuleObject = 'HeatBalanceSettings:ConductionFiniteDifference'

  IF (GetNumObjectsFound(cCurrentModuleObject) > 0) THEN
    CALL GetObjectItem(cCurrentModuleObject,1,cAlphaArgs,NumAlphas, &
                       rNumericArgs,NumNumbers,IOSTAT,  &
                   AlphaBlank=lAlphaFieldBlanks,NumBlank=lNumericFieldBlanks,  &
                   AlphaFieldnames=cAlphaFieldNames,NumericFieldNames=cNumericFieldNames)

    IF (.NOT. lAlphaFieldBlanks(1)) THEN

      SELECT CASE (cAlphaArgs(1))

      CASE ('CRANKNICHOLSONSECONDORDER')
        CondFDSchemeType = CrankNicholsonSecondOrder
      CASE ('FULLYIMPLICITFIRSTORDER')
        CondFDSchemeType = FullyImplicitFirstOrder
      CASE DEFAULT
        CALL ShowSevereError(TRIM(cCurrentModuleObject)//': invalid '//TRIM(cAlphaFieldNames(1))//  &
         ' entered='//TRIM(cAlphaArgs(1))//', must match CrankNicholsonSecondOrder or FullyImplicitFirstOrder.')
        ErrorsFound=.true.
      END SELECT

    ENDIF

    IF (.NOT. lNumericFieldBlanks(1)) THEN
      SpaceDescritConstant = rNumericArgs(1)
    ENDIF
    IF (.NOT. lNumericFieldBlanks(2)) THEN
      CondFDRelaxFactorInput = rNumericArgs(2)
      CondFDRelaxFactor      = CondFDRelaxFactorInput
    ENDIF
    IF (.NOT. lNumericFieldBlanks(3)) THEN
      MaxAllowedDelTempCondFD = rNumericArgs(3)
    ENDIF

  ENDIF ! settings object

  pcMat=GetNumObjectsFound('MaterialProperty:PhaseChange')
  vcMat=GetNumObjectsFound('MaterialProperty:VariableThermalConductivity')
!VE START
CondFDMat=GetNumObjectsFound('MaterialProperty:PhaseChangeHysteresis')
!VE END    
  ALLOCATE(MaterialFD(TotMaterials))

  ! Load the additional CondFD Material properties
  cCurrentModuleObject='MaterialProperty:PhaseChange'    ! Phase Change Information First

  IF ( pcMat .NE. 0 ) Then                      !  Get Phase Change info
!    CondFDVariableProperties = .TRUE.
    DO Loop=1,pcMat

    !Call Input Get routine to retrieve material data
      CALL GetObjectItem(cCurrentModuleObject,Loop,MaterialNames,MaterialNumAlpha, &
                       MaterialProps,MaterialNumProp,IOSTAT,  &
                   AlphaBlank=lAlphaFieldBlanks,NumBlank=lNumericFieldBlanks,  &
                   AlphaFieldnames=cAlphaFieldNames,NumericFieldNames=cNumericFieldNames)


    !Load the material derived type from the input data.
      MaterNum = FindItemInList(MaterialNames(1),Material%Name,TotMaterials)
      IF (MaterNum == 0) THEN
        CALL ShowSevereError(TRIM(cCurrentModuleObject)//': invalid '//TRIM(cAlphaFieldNames(1))//  &
           ' entered='//TRIM(MaterialNames(1))//', must match to a valid Material name.')
        ErrorsFound=.true.
        Cycle
      ENDIF

      IF (Material(MaterNum)%Group /= RegularMaterial) THEN
        CALL ShowSevereError(TRIM(cCurrentModuleObject)//  &
           ': Reference Material is not appropriate type for CondFD properties, material='//  &
           TRIM(Material(MaterNum)%Name)//', must have regular properties (L,Cp,K,D)')
        ErrorsFound=.true.
      ENDIF


    ! Once the material derived type number is found then load the additional CondFD variable material properties
    !   Some or all may be zero (default).  They will be checked when calculating node temperatures
      MaterialFD(MaterNum)%tk1          = MaterialProps(1)
      MaterialFD(MaterNum)%numTempEnth  = (MaterialNumProp-1)/2
      IF (MaterialFD(MaterNum)%numTempEnth*2 /= (MaterialNumProp-1)) THEN
        CALL ShowSevereError('GetCondFDInput: '//trim(cCurrentModuleObject)//'="'//trim(MaterialNames(1))//  &
           '", mismatched pairs')
        CALL ShowContinueError('...expected '//trim(RoundSigDigits(MaterialFD(MaterNum)%numTempEnth))//  &
           ' pairs, but only entered '//trim(RoundSigDigits(MaterialNumProp-1))//' numbers.')
        ErrorsFound=.true.
      ENDIF
      ALLOCATE(MaterialFD(MaterNum)%TempEnth(MaterialFD(MaterNum)%numTempEnth,2))
      MaterialFD(MaterNum)%TempEnth     =0.0d0
      propNum=2
      ! Temperature first
      DO pcount=1,MaterialFD(MaterNum)%numTempEnth
        MaterialFD(MaterNum)%TempEnth(pcount,1)   = MaterialProps(propNum)
        propNum=propNum+2
      ENDDO
      propNum=3
      ! Then Enthalpy
      DO pcount=1,MaterialFD(MaterNum)%numTempEnth
        MaterialFD(MaterNum)%TempEnth(pcount,2)   = MaterialProps(propNum)
        propNum=propNum+2
      ENDDO
      nonInc=.false.
      inegptr=0
      DO pcount=1,MaterialFD(MaterNum)%numTempEnth-1
        IF (MaterialFD(MaterNum)%TempEnth(pcount,1) < MaterialFD(MaterNum)%TempEnth(pcount+1,1)) CYCLE
        nonInc=.true.
        inegptr=pcount+1
        EXIT
      ENDDO
      IF (nonInc) THEN
        CALL ShowSevereError('GetCondFDInput: '//trim(cCurrentModuleObject)//'="'//trim(MaterialNames(1))//  &
           '", non increasing Temperatures. Temperatures must be strictly increasing.')
        CALL ShowContinueError('...occurs first at item=['//trim(RoundSigDigits(inegptr))//'], value=['//  &
           trim(RoundSigDigits(MaterialFD(MaterNum)%TempEnth(inegptr,1),2))//'].')
        ErrorsFound=.true.
      ENDIF
      nonInc=.false.
      inegptr=0
      DO pcount=1,MaterialFD(MaterNum)%numTempEnth-1
        IF (MaterialFD(MaterNum)%TempEnth(pcount,2) <= MaterialFD(MaterNum)%TempEnth(pcount+1,2)) CYCLE
        nonInc=.true.
        inegptr=pcount+1
        EXIT
      ENDDO
      IF (nonInc) THEN
        CALL ShowSevereError('GetCondFDInput: '//trim(cCurrentModuleObject)//'="'//trim(MaterialNames(1))//  &
           '", non increasing Enthalpy.')
        CALL ShowContinueError('...occurs first at item=['//trim(RoundSigDigits(inegptr))//'], value=['//  &
           trim(RoundSigDigits(MaterialFD(MaterNum)%TempEnth(inegptr,2),2))//'].')
        CALL ShowContinueError('...These values may be Cp (Specific Heat) rather than Enthalpy.  Please correct.')
        ErrorsFound=.true.
      ENDIF
    ENDDO
  END IF
!VE START
!****************************************************************************************************************************** 
    cCurrentModuleObject='MaterialProperty:PhaseChangeHysteresis'    ! Phase Change Information First
    CondFDMat=GetNumObjectsFound(TRIM(cCurrentModuleObject))
    
    IF ( CondFDMat .NE. 0 ) Then                      !  Get Dual Curve Phase Change info
        DO Loop=1,CondFDMat

            !Call Input Get routine to retrieve material data
            CALL GetObjectItem(TRIM(cCurrentModuleObject),Loop,MaterialNames,MaterialNumAlpha, &
                                MaterialProps,MaterialNumProp,IOSTAT,  &
                            AlphaBlank=lAlphaFieldBlanks,NumBlank=lNumericFieldBlanks,  &
                            AlphaFieldnames=cAlphaFieldNames,NumericFieldNames=cNumericFieldNames)
        
            MaterNum = FindItemInList(MaterialNames(1),Material%Name,TotMaterials)
            IF (MaterNum == 0) THEN
                CALL ShowSevereError(TRIM(cCurrentModuleObject)//': invalid '//TRIM(cAlphaFieldNames(1))//  &
                     ' entered='//TRIM(MaterialNames(1))//', must match to a valid Material name.')
                  ErrorsFound=.true.
                CYCLE
            ENDIF

            IF (Material(MaterNum)%Group /= RegularMaterial) THEN
              CALL ShowSevereError(TRIM(cCurrentModuleObject)//  &
                 ': Reference Material is not appropriate type for CondFD properties, material='//  &
                 TRIM(Material(MaterNum)%Name)//', must have regular properties (L,Cp,K,D)')
              ErrorsFound=.true.
            ENDIF
            
          Material(MaterNum)%tk1        =     MaterialProps(1)    ! Temperature coefficient for thermal conductivity      
          Material(MaterNum)%DeltaHS    =     MaterialProps(2)    ! Latent Heat of Fusion 
          Material(MaterNum)%CpLiquid   =     MaterialProps(3)    ! Specific Heat of PCM in Liquid State
          Material(MaterNum)%Tau2       =     MaterialProps(4)    ! High Temperature Difference of melting curve 
          Material(MaterNum)%Tm         =     MaterialProps(5)    ! Peak Melting Temperature PeakMeltTemp 
          Material(MaterNum)%Tau1       =     MaterialProps(6)    ! Low Temperature Difference of melting curve  
          Material(MaterNum)%DeltaHF    =     MaterialProps(7)    ! Latent Heat Of Solidification 
          Material(MaterNum)%CpSolid    =     MaterialProps(8)    ! Specific Heat of PCM in Solid State
          Material(MaterNum)%Tau2Prime  =     MaterialProps(9)    ! High Temperature Difference of freezing curve 
          Material(MaterNum)%Tf         =     MaterialProps(10)   ! Peak Freezing Temperature 
          Material(MaterNum)%Tau1Prime  =     MaterialProps(11)   ! Low Temperature Difference of freezing curve           
        END DO
    END IF
!VE- CondFDVariableProperties = .TRUE.
!VE END 
!   Get CondFD Variable Thermal Conductivity Input

  cCurrentModuleObject='MaterialProperty:VariableThermalConductivity'    ! Variable Thermal Conductivity Info next
  IF ( vcMat .NE. 0 ) Then   !  variable k info
!    CondFDVariableProperties = .TRUE.
    DO Loop=1,vcMat

      !Call Input Get routine to retrieve material data
      CALL GetObjectItem(cCurrentModuleObject,Loop,MaterialNames,MaterialNumAlpha, &
                   MaterialProps,MaterialNumProp,IOSTAT,  &
                   AlphaBlank=lAlphaFieldBlanks,NumBlank=lNumericFieldBlanks,  &
                   AlphaFieldnames=cAlphaFieldNames,NumericFieldNames=cNumericFieldNames)


      !Load the material derived type from the input data.
      MaterNum = FindItemInList(MaterialNames(1),Material%Name,TotMaterials)
      IF (MaterNum == 0) THEN
        CALL ShowSevereError(TRIM(cCurrentModuleObject)//': invalid '//TRIM(cAlphaFieldNames(1))//  &
         ' entered='//TRIM(MaterialNames(1))//', must match to a valid Material name.')
        ErrorsFound=.true.
        Cycle
      ENDIF

      IF (Material(MaterNum)%Group /= RegularMaterial) THEN
        CALL ShowSevereError(TRIM(cCurrentModuleObject)//  &
           ': Reference Material is not appropriate type for CondFD properties, material='//  &
           TRIM(Material(MaterNum)%Name)//', must have regular properties (L,Cp,K,D)')
        ErrorsFound=.true.
      ENDIF


    ! Once the material derived type number is found then load the additional CondFD variable material properties
    !   Some or all may be zero (default).  They will be checked when calculating node temperatures
      MaterialFD(MaterNum)%numTempCond  = MaterialNumProp/2
      IF (MaterialFD(MaterNum)%numTempCond*2 /= MaterialNumProp) THEN
        CALL ShowSevereError('GetCondFDInput: '//trim(cCurrentModuleObject)//'="'//trim(MaterialNames(1))//  &
           '", mismatched pairs')
        CALL ShowContinueError('...expected '//trim(RoundSigDigits(MaterialFD(MaterNum)%numTempCond))//  &
           ' pairs, but only entered '//trim(RoundSigDigits(MaterialNumProp))//' numbers.')
        ErrorsFound=.true.
      ENDIF
      ALLOCATE(MaterialFD(MaterNum)%TempCond(MaterialFD(MaterNum)%numTempCond,2))
      MaterialFD(MaterNum)%TempCond    =0.0d0
      propNum=1
      ! Temperature first
      DO pcount=1,MaterialFD(MaterNum)%numTempCond
        MaterialFD(MaterNum)%TempCond(pcount,1)   = MaterialProps(propNum)
        propNum=propNum+2
      ENDDO
      propNum=2
      ! Then Conductivity
      DO pcount=1,MaterialFD(MaterNum)%numTempCond
        MaterialFD(MaterNum)%TempCond(pcount,2)   = MaterialProps(propNum)
        propNum=propNum+2
      ENDDO
      nonInc=.false.
      inegptr=0
      DO pcount=1,MaterialFD(MaterNum)%numTempCond-1
        IF (MaterialFD(MaterNum)%TempCond(pcount,1) < MaterialFD(MaterNum)%TempCond(pcount+1,1)) CYCLE
        nonInc=.true.
        inegptr=pcount+1
        EXIT
      ENDDO
      IF (nonInc) THEN
        CALL ShowSevereError('GetCondFDInput: '//trim(cCurrentModuleObject)//'="'//trim(MaterialNames(1))//  &
           '", non increasing Temperatures. Temperatures must be strictly increasing.')
        CALL ShowContinueError('...occurs first at item=['//trim(RoundSigDigits(inegptr))//'], value=['//  &
           trim(RoundSigDigits(MaterialFD(MaterNum)%TempCond(inegptr,1),2))//'].')
        ErrorsFound=.true.
      ENDIF
    ENDDO
  END IF

  DO MaterNum=1,TotMaterials
    IF (MaterialFD(MaterNum)%numTempEnth == 0) THEN
      MaterialFD(MaterNum)%numTempEnth=3
      ALLOCATE(MaterialFD(MaterNum)%TempEnth(MaterialFD(MaterNum)%numTempEnth,2))
      MaterialFD(MaterNum)%TempEnth=-100.0d0
    ENDIF
    IF (MaterialFD(MaterNum)%numTempCond == 0) THEN
      MaterialFD(MaterNum)%numTempCond=3
      ALLOCATE(MaterialFD(MaterNum)%TempCOnd(MaterialFD(MaterNum)%numTempCond,2))
      MaterialFD(MaterNum)%TempCond=-100.0d0
    ENDIF
  ENDDO

  IF (ErrorsFound) THEN
    CALL ShowFatalError('GetCondFDInput: Errors found getting ConductionFiniteDifference properties. Program terminates.')
  ENDIF

  CALL InitialInitHeatBalFiniteDiff

  RETURN

END SUBROUTINE GetCondFDInput

SUBROUTINE InitHeatBalFiniteDiff

          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard J. Liesen
          !       DATE WRITTEN   Oct 2003
          !       MODIFIED       na
          !       RE-ENGINEERED  C O Pedersen 2006
          !                      B. Griffith May 2011 move begin-environment and every-timestep inits, cleanup formatting

          ! PURPOSE OF THIS SUBROUTINE:
          ! This subroutine sets the initial values for the FD moisture calculation

          ! METHODOLOGY EMPLOYED:

          ! REFERENCES:
          !

          ! USE STATEMENTS:
  USE DataInterfaces, ONLY:SetupOutputVariable
  USE DataSurfaces, ONLY: HeatTransferModel_CondFD

  IMPLICIT NONE    ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS
          ! na

          ! DERIVED TYPE DEFINITIONS
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
  LOGICAL,SAVE        :: MyEnvrnFlag=.TRUE.
  INTEGER :: SurfNum
  INTEGER :: ConstrNum    ! Loop counter
  LOGICAL :: errorsFound

  IF (GetHBFiniteDiffInputFlag) THEN
      ! Obtains conduction FD related parameters from input file
    CALL GetCondFDInput
    GetHBFiniteDiffInputFlag=.false.
  ENDIF

  errorsFound=.false.

  ! now do begin environment inits.
  IF (BeginEnvrnFlag .AND. MyEnvrnFlag) THEN
    DO SurfNum=1,TotSurfaces
      IF (Surface(SurfNum)%HeatTransferAlgorithm /= HeatTransferModel_CondFD)   CYCLE
      IF(Surface(SurfNum)%Construction <= 0) CYCLE  ! Shading surface, not really a heat transfer surface
      ConstrNum=Surface(SurfNum)%Construction
      IF(Construct(ConstrNum)%TypeIsWindow) CYCLE  !  Windows simulated in Window module
      SurfaceFD(SurfNum)%T              = TempInitValue
      SurfaceFD(SurfNum)%TOld           = TempInitValue
      SurfaceFD(SurfNum)%TT             = TempInitValue
      SurfaceFD(SurfNum)%Rhov           = RhovInitValue
      SurfaceFD(SurfNum)%RhovOld        = RhovInitValue
      SurfaceFD(SurfNum)%RhoT           = RhovInitValue
      SurfaceFD(SurfNum)%TD             = TempInitValue
      SurfaceFD(SurfNum)%TDT            = TempInitValue
      SurfaceFD(SurfNum)%TDTLast        = TempInitValue
      SurfaceFD(SurfNum)%TDOld          = TempInitValue
      SurfaceFD(SurfNum)%TDreport       = TempInitValue
      SurfaceFD(SurfNum)%RH             = 0.0d0
      SurfaceFD(SurfNum)%RHreport       = 0.0d0
      SurfaceFD(SurfNum)%EnthOld        = EnthInitValue
      SurfaceFD(SurfNum)%EnthNew        = EnthInitValue
      SurfaceFD(SurfNum)%EnthLast       = EnthInitValue

      TempOutsideAirFD(SurfNum)         = 0.d0
      RhoVaporAirOut(SurfNum)           = 0.d0
      RhoVaporSurfIn(SurfNum)           = 0.d0
      RhoVaporAirIn(SurfNum)            = 0.d0
      HConvExtFD(SurfNum)               = 0.d0
      HMassConvExtFD(SurfNum)           = 0.d0
      HConvInFD(SurfNum)                = 0.d0
      HMassConvInFD(SurfNum)            = 0.d0
      HSkyFD(SurfNum)                   = 0.d0
      HGrndFD(SurfNum)                  = 0.d0
      HAirFD(SurfNum)                   = 0.d0
    ENDDO
    WarmupSurfTemp=0
    MyEnvrnFlag = .FALSE.
  END IF
  IF (.NOT. BeginEnvrnFlag) THEN
    MyEnvrnFlag=.TRUE.
  ENDIF

  ! now do every timestep inits

  DO SurfNum=1,TotSurfaces
    IF (Surface(SurfNum)%HeatTransferAlgorithm /= HeatTransferModel_CondFD)  CYCLE
    IF(Surface(SurfNum)%Construction <= 0) CYCLE  ! Shading surface, not really a heat transfer surface
    ConstrNum=Surface(SurfNum)%Construction
    IF(Construct(ConstrNum)%TypeIsWindow) CYCLE  !  Windows simulated in Window module
    SurfaceFD(SurfNum)%T        = SurfaceFD(SurfNum)%TOld
    SurfaceFD(SurfNum)%Rhov     = SurfaceFD(SurfNum)%RhovOld
    SurfaceFD(SurfNum)%TD       = SurfaceFD(SurfNum)%TDOld
    SurfaceFD(SurfNum)%TDT      = SurfaceFD(SurfNum)%TDreport !PT changes from TDold to TDreport
    SurfaceFD(SurfNum)%TDTLast  = SurfaceFD(SurfNum)%TDOld
    SurfaceFD(SurfNum)%EnthOld  = SurfaceFD(SurfNum)%EnthOld
    SurfaceFD(SurfNum)%EnthNew  = SurfaceFD(SurfNum)%EnthOld
    SurfaceFD(SurfNum)%EnthLast = SurfaceFD(SurfNum)%EnthOld
  ENDDO

  RETURN

END SUBROUTINE InitHeatBalFiniteDiff


SUBROUTINE InitialInitHeatBalFiniteDiff

          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Linda Lawrie
          !       DATE WRITTEN   March 2012
          !       MODIFIED       na
          !       RE-ENGINEERED  na

          ! PURPOSE OF THIS SUBROUTINE:
          ! This routine performs the original allocate, inits and setup output variables for the
          ! module.

          ! METHODOLOGY EMPLOYED:
          ! na

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
  USE General,         ONLY : TrimSigDigits, RoundSigDigits
  USE DataSurfaces,    ONLY : HeatTransferModel_CondFD
  USE DataHeatBalance, Only: HighDiffusivityThreshold, ThinMaterialLayerThreshold

  IMPLICIT NONE ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
          ! na

          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS:
          ! na

          ! DERIVED TYPE DEFINITIONS:
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
  INTEGER :: Lay
  INTEGER :: SurfNum
  CHARACTER(len=MaxNameLength) :: LayChar

  REAL(r64) :: dxn              ! Intermediate calculation of nodal spacing. This is the full dx. There is
                                ! a half dxn thick node at each surface. dxn is the "capacitor" spacing.
  INTEGER :: ipts1              ! Intermediate calculation for number of full thickness nodes per layer. There
                                ! are always two half nodes at the layer faces.
  INTEGER :: Layer              ! Loop counter
  INTEGER :: OutwardMatLayerNum ! layer index, layer outward of the current layer
  INTEGER :: layerNode
  INTEGER :: Delt
  INTEGER :: ConstrNum    ! Loop counter
  INTEGER :: TotNodes     ! Loop counter
  INTEGER :: CurrentLayer ! Loop counter
  INTEGER :: Surf         ! Loop counter
  INTEGER :: index        ! Loop Counters

  REAL(r64) :: Alpha
  REAL(r64) :: Malpha
  REAL(r64) :: stabilitytemp
  REAL(r64) :: stabilitymoist
  REAL(r64) :: a
  REAL(r64) :: b
  REAL(r64) :: c
  REAL(r64) :: d
  REAL(r64) :: kt
  REAL(r64) :: RhoS
  REAL(r64) :: Por
  REAL(r64) :: Cp
  REAL(r64) :: Dv
  LOGICAL :: errorsFound
  REAL(r64) :: DeltaTimestep      ! zone timestep in seconds, for local check of properties
  REAL(r64) :: ThicknessThreshold ! min thickness consistent with other thermal properties, for local check
!VE START
   REAL(r64) :: EnthInit
   REAL(r64) :: TempInit
   REAL(r64) :: RhoVInit
!VE END 
  ALLOCATE(ConstructFD(TotConstructs))
  ALLOCATE(SigmaR(TotConstructs))
  ALLOCATE(SigmaC(TotConstructs))

  ALLOCATE(SurfaceFD(TotSurfaces))
  ALLOCATE(QHeatInFlux(TotSurfaces))
  ALLOCATE(QHeatOutFlux(TotSurfaces))
!  ALLOCATE(QFluxInArrivSurfCond(TotSurfaces))
!  ALLOCATE(QFluxOutArrivSurfCond(TotSurfaces))
!  ALLOCATE(OpaqSurfInsFaceConductionFlux(TotSurfaces))
!  ALLOCATE(OpaqSurfOutsideFaceConductionFlux(TotSurfaces))
! VE START
  ALLOCATE(QFluxZoneToInSurf(TotSurfaces))
! VE END
!  ALLOCATE(QFluxOutsideToOutSurf(TotSurfaces))

 ! And then initialize
  QHeatInFlux  = 0.d0
  QHeatOutFlux  = 0.d0
! VE START
  QFluxZoneToInSurf  = 0.d0
! VE END
  !QFluxOutsideToOutSurf  = 0.d0
  !QFluxInArrivSurfCond  = 0.d0
  !QFluxOutArrivSurfCond  = 0.d0
  OpaqSurfInsFaceConductionFlux = 0.d0
  OpaqSurfOutsideFaceConductionFlux = 0.d0
!VE START
    TempInit = 20.0d0
    RhovInit = 0.0115d0
    EnthInit = 100.0d0
!VE END 
  ! Setup Output Variables

  !  set a Delt that fits the zone time step and keeps it below 200s.

  fracTimeStepZone_Hour=1.0d0/REAL(NumOfTimeStepInHour,r64)

  DO index = 1, 20
    Delt = (fracTimeStepZone_Hour*SecInHour)/index   ! TimeStepZone = Zone time step in fractional hours
    IF ( Delt <= 200 )  EXIT
  END DO

  DO ConstrNum = 1, TotConstructs
    !Need to skip window constructions and eventually window materials
    IF(Construct(ConstrNum)%TypeIsWindow) CYCLE

    ALLOCATE(ConstructFD(ConstrNum)%Name(Construct(ConstrNum)%TotLayers))
    ALLOCATE(ConstructFD(ConstrNum)%Thickness(Construct(ConstrNum)%TotLayers))
    ALLOCATE(ConstructFD(ConstrNum)%NodeNumPoint(Construct(ConstrNum)%TotLayers))
    ALLOCATE(ConstructFD(ConstrNum)%DelX(Construct(ConstrNum)%TotLayers))
    ALLOCATE(ConstructFD(ConstrNum)%TempStability(Construct(ConstrNum)%TotLayers))
    ALLOCATE(ConstructFD(ConstrNum)%MoistStability(Construct(ConstrNum)%TotLayers))
      ! Node Number of the Interface node following each layer
!    ALLOCATE(ConstructFD(ConstrNum)%InterfaceNodeNums(Construct(ConstrNum)%TotLayers))


    TotNodes = 0
    SigmaR(ConstrNum) =0.0d0
    SigmaC(ConstrNum) =0.0d0

    DO Layer = 1, Construct(ConstrNum)%TotLayers    ! Begin layer loop ...

          ! Loop through all of the layers in the current construct. The purpose
          ! of this loop is to define the thermal properties  and to.
          ! determine the total number of full size nodes in each layer.
          ! The number of temperature points is one more than this
          ! because of the two half nodes at the layer faces.
          ! The calculation of dxn used here is based on a standard stability
          ! criteria for explicit finite difference solutions.  This criteria
          ! was chosen not because it is viewed to be correct, but rather for
          ! lack of any better criteria at this time.  The use of a Fourier
          ! number based criteria such as this is probably physically correct.
          ! Change to implicit formulation still uses explicit stability, but
          ! now there are special equations for R-only layers.

      CurrentLayer = Construct(ConstrNum)%LayerPoint(Layer)


      ConstructFD(ConstrNum)%Name(Layer) = Material(CurrentLayer)%Name
      ConstructFD(ConstrNum)%Thickness(Layer) = Material(CurrentLayer)%Thickness

     ! Do some quick error checks for this section.

      IF (Material(CurrentLayer)%ROnly  ) THEN  ! Rlayer

        ! These values are only needed temporarily and to calculate flux,
        !   Layer will be handled
        !  as a pure R in the temperature calc.
        ! assign other properties based on resistance

        Material(CurrentLayer)%SpecHeat  = 0.0001d0
        Material(CurrentLayer)%Density = 1.d0
        Material(currentLayer)%Thickness = 0.1d0  !  arbitrary thickness for R layer
        Material(CurrentLayer)%Conductivity= &
        Material(currentLayer)%Thickness/Material(CurrentLayer)%Resistance
        kt = Material(CurrentLayer)%Conductivity
        ConstructFD(ConstrNum)%Thickness(Layer) = Material(CurrentLayer)%Thickness

        SigmaR(ConstrNum) = SigmaR(ConstrNum) + Material(CurrentLayer)%Resistance  ! add resistance of R layer
        SigmaC(ConstrNum) = SigmaC(ConstrNum)  + 0.0d0                               !  no capacitance for R layer

        Alpha = kt/(Material(CurrentLayer)%Density*Material(CurrentLayer)%SpecHeat)

        mAlpha = 0.d0

      ELSE IF (Material(CurrentLayer)%Group == 1 ) THEN   !  Group 1 = Air

                !  Again, these values are only needed temporarily and to calculate flux,
                !   Air layer will be handled
                !  as a pure R in the temperature calc.
                !
                ! assign
                ! other properties based on resistance

        Material(CurrentLayer)%SpecHeat  = 0.0001d0
        Material(CurrentLayer)%Density = 1.d0
        Material(currentLayer)%Thickness = 0.1d0  !  arbitrary thickness for R layer
        Material(currentLayer)%Conductivity= &
        Material(currentLayer)%Thickness/Material(CurrentLayer)%Resistance
        kt = Material(CurrentLayer)%Conductivity
        ConstructFD(ConstrNum)%Thickness(Layer) = Material(CurrentLayer)%Thickness

        SigmaR(ConstrNum) = SigmaR(ConstrNum) + Material(CurrentLayer)%Resistance  ! add resistance of R layer
        SigmaC(ConstrNum) = SigmaC(ConstrNum)  + 0.0d0                               !  no capacitance for R layer

        Alpha = kt/(Material(CurrentLayer)%Density*Material(CurrentLayer)%SpecHeat)
        mAlpha = 0.d0
      ELSE IF (Construct(ConstrNum)%TypeIsIRT) THEN  ! make similar to air? (that didn't seem to work well)
        CALL ShowSevereError('InitHeatBalFiniteDiff: Construction ="'//trim(Construct(ConstrNum)%Name)//  &
             '" uses Material:InfraredTransparent. Cannot be used currently with finite difference calculations.')
        IF (Construct(ConstrNum)%IsUsed) THEN
          CALL ShowContinueError('...since this construction is used in a surface, the simulation is not allowed.')
          errorsFound=.true.
        ELSE
          CALL ShowContinueError('...if this construction were used in a surface, the simulation would be terminated.')
        ENDIF
        CYCLE
!            ! set properties to get past other initializations.
!          Material(CurrentLayer)%SpecHeat  = 0.0001d0
!          Material(CurrentLayer)%Density = 0.0001d0
!          Material(currentLayer)%Thickness = 0.1d0  !  arbitrary thickness for R layer
!          Material(currentLayer)%Conductivity= &
!    -      Material(currentLayer)%Thickness/Material(CurrentLayer)%Resistance
!          kt = Material(CurrentLayer)%Conductivity
!          ConstructFD(ConstrNum)%Thickness(Layer) = Material(CurrentLayer)%Thickness
!
!          SigmaR(ConstrNum) = SigmaR(ConstrNum) + Material(CurrentLayer)%Resistance  ! add resistance of R layer
!          SigmaC(ConstrNum) = SigmaC(ConstrNum)  + 0.0                               !  no capacitance for R layer
!
!          Alpha = kt/(Material(CurrentLayer)%Density*Material(CurrentLayer)%SpecHeat)
!          mAlpha = 0.d0
      ELSE
       !    Regular material Properties
        a = Material(CurrentLayer)%MoistACoeff
        b = Material(CurrentLayer)%MoistBCoeff
        c = Material(CurrentLayer)%MoistCCoeff
        d = Material(CurrentLayer)%MoistDCoeff
        kt = Material(CurrentLayer)%Conductivity
        RhoS = Material(CurrentLayer)%Density
        Por = Material(CurrentLayer)%Porosity
        Cp = Material(CurrentLayer)%SpecHeat
         ! Need Resistance for reg layer
        Material(CurrentLayer)%Resistance = Material(currentLayer)%Thickness/Material(CurrentLayer)%Conductivity
        Dv = Material(CurrentLayer)%VaporDiffus
        SigmaR(ConstrNum) = SigmaR(ConstrNum) + Material(CurrentLayer)%Resistance  ! add resistance
        SigmaC(ConstrNum) = SigmaC(ConstrNum)  + &
        Material(CurrentLayer)%Density*Material(CurrentLayer)%SpecHeat*Material(CurrentLayer)%Thickness
        Alpha = kt/(RhoS*Cp)
        !   Alpha = kt*(Por+At*RhoS)/(RhoS*(Bv*Por*Lambda+Cp*(Por+At*RhoS)))
        MAlpha = 0.d0

        !check for Material layers that are too thin and highly conductivity (not appropriate for surface models)
        IF (Alpha > HighDiffusivityThreshold .AND. .NOT. Material(CurrentLayer)%WarnedForHighDiffusivity) THEN
          DeltaTimestep      = TimeStepZone * SecInHour
          ThicknessThreshold = SQRT(Alpha * DeltaTimestep * 3.d0)
          IF (Material(CurrentLayer)%Thickness < ThicknessThreshold) THEN
            CALL ShowSevereError('InitialInitHeatBalFiniteDiff: Found Material that is too thin and/or too highly conductive,' &
                                    //' material name = '  // TRIM(Material(CurrentLayer)%Name))
            CALL ShowContinueError('High conductivity Material layers are not well supported by Conduction Finite Difference, ' &
                                    //' material conductivity = ' //TRIM(RoundSigDigits(Material(CurrentLayer)%Conductivity, 3)) &
                                    //' [W/m-K]')
            CALL ShowContinueError('Material thermal diffusivity = ' //TRIM(RoundSigDigits(Alpha, 3)) //' [m2/s]')
            CALL ShowContinueError('Material with this thermal diffusivity should have thickness > ' &
                                      //  TRIM(RoundSigDigits(ThicknessThreshold , 5)) // ' [m]')
            IF (Material(CurrentLayer)%Thickness < ThinMaterialLayerThreshold) THEN
              CALL ShowContinueError('Material may be too thin to be modeled well, thickness = ' &
                                      // TRIM(RoundSigDigits(Material(currentLayer)%Thickness, 5 ))//' [m]')
              CALL ShowContinueError('Material with this thermal diffusivity should have thickness > ' &
                                      //  TRIM(RoundSigDigits(ThinMaterialLayerThreshold , 5)) // ' [m]')
            ENDIF
            Material(CurrentLayer)%WarnedForHighDiffusivity = .TRUE.
          ENDIF
        ENDIF

      END IF  !  R, Air  or regular material properties and parameters

     ! Proceed with setting node sizes in layers

      DXN=SQRT(Alpha*Delt*SpaceDescritConstant)  ! The Fourier number is set using user constant

       ! number of nodes=thickness/spacing.  This is number of full size node spaces across layer.
      Ipts1=INT(Material(CurrentLayer)%Thickness/DXN)
       !  set high conductivity layers to a single full size node thickness. (two half nodes)
      IF(Ipts1 <= 1) Ipts1 = 1
      IF (Material(CurrentLayer)%ROnly .or. Material(CurrentLayer)%Group == 1 ) THEN

        Ipts1 = 1  !  single full node in R layers- surfaces of adjacent material or inside/outside layer
      END If

      Dxn=Material(CurrentLayer)%Thickness/REAL(Ipts1,r64)  ! full node thickness

      StabilityTemp = Alpha*Delt/dxn**2
      StabilityMoist = malpha*Delt/dxn**2
      ConstructFD(ConstrNum)%TempStability(Layer) = StabilityTemp
      ConstructFD(ConstrNum)%MoistStability(Layer) = StabilityMoist
      ConstructFD(ConstrNum)%Delx(Layer) = DXN

      TotNodes = TotNodes + Ipts1   !  number of full size nodes
      ConstructFD(ConstrNum)%NodeNumPoint(Layer) = Ipts1   !  number of full size nodes
    END DO   !  end of layer loop.


    ConstructFD(ConstrNum)%TotNodes = TotNodes
    ConstructFD(ConstrNum)%DeltaTime = Delt



  END DO            ! End of Construction Loop.  TotNodes in each construction now set

  ! now determine x location, or distance that nodes are from the outside face in meters
  DO ConstrNum = 1, TotConstructs
     IF (ConstructFD(ConstrNum)%TotNodes > 0) THEN
       ALLOCATE(ConstructFD(ConstrNum)%NodeXlocation(ConstructFD(ConstrNum)%TotNodes + 1 ))
       ConstructFD(ConstrNum)%NodeXlocation = 0.d0 ! init them all
       Ipts1 = 0 ! init counter
       DO Layer = 1, Construct(ConstrNum)%TotLayers
         OutwardMatLayerNum = Layer - 1
         DO layerNode = 1, ConstructFD(ConstrNum)%NodeNumPoint(Layer)
           Ipts1 = Ipts1 +1
           IF (Ipts1 == 1) THEN
             ConstructFD(ConstrNum)%NodeXlocation(Ipts1) = 0.d0 ! first node is on outside face

           ELSEIF (LayerNode == 1) THEN
             IF ( OutwardMatLayerNum > 0 .AND. OutwardMatLayerNum <= Construct(ConstrNum)%TotLayers ) THEN
             ! later nodes are Delx away from previous, but use Delx from previous layer
               ConstructFD(ConstrNum)%NodeXlocation(Ipts1) = ConstructFD(ConstrNum)%NodeXlocation(Ipts1 - 1) &
                                                           + ConstructFD(ConstrNum)%Delx(OutwardMatLayerNum)
             ENDIF
           ELSE
             ! later nodes are Delx away from previous
             ConstructFD(ConstrNum)%NodeXlocation(Ipts1) = ConstructFD(ConstrNum)%NodeXlocation(Ipts1 - 1) &
                                                           + ConstructFD(ConstrNum)%Delx(Layer)
           ENDIF

         ENDDO
       ENDDO
       Layer = Construct(ConstrNum)%TotLayers
       Ipts1 = Ipts1 +1
       ConstructFD(ConstrNum)%NodeXlocation(Ipts1) = ConstructFD(ConstrNum)%NodeXlocation(Ipts1 - 1) &
                                                           + ConstructFD(ConstrNum)%Delx(Layer)
     ENDIF
  ENDDO

  DO Surf = 1,TotSurfaces
    IF (.not. Surface(Surf)%HeatTransSurf) CYCLE
    IF (Surface(Surf)%Class == SurfaceClass_Window) CYCLE
    IF (Surface(Surf)%HeatTransferAlgorithm /= HeatTransferModel_CondFD) CYCLE
!    IF(Surface(Surf)%Construction <= 0) CYCLE  ! Shading surface, not really a heat transfer surface
    ConstrNum=Surface(surf)%Construction
!    IF(Construct(ConstrNum)%TypeIsWindow) CYCLE  !  Windows simulated in Window module
    TotNodes = ConstructFD(ConstrNum)%TotNodes

     !Allocate the Surface Arrays
    ALLOCATE(SurfaceFD(Surf)%T(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%TOld(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%TT(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%Rhov(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%RhovOld(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%RhoT(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%TD(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%TDT(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%TDTLast(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%TDOld(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%TDreport(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%RH(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%RHreport(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%EnthOld(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%EnthNew(TotNodes + 1))
    ALLOCATE(SurfaceFD(Surf)%EnthLast(TotNodes + 1))
!VE START
   ALLOCATE(SurfaceFD(Surf)%TempLastStep(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%Enthreport(TotNodes + 1)) 
   ALLOCATE(SurfaceFD(Surf)%EnthLastStep(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%CpOld(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%CpOld1(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%CpOld2(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%Cp_node(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%Cp1_node(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%Cp2_node(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeDeltaT(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeDeltaTOld(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeTransition(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeTransitionOld(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeState(TotNodes + 1))  
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeStateold(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeStateoldold(TotNodes + 1))
   ALLOCATE(SurfaceFD(Surf)%PhaseChangeTemperatureReverse(TotNodes + 1)) 
   SurfaceFD(Surf)%Enthreport       = EnthInit 
   SurfaceFD(Surf)%EnthLastStep     = EnthInit
   SurfaceFD(Surf)%CpOld      = 1200 ! SpecHeatSolidPCM
   SurfaceFD(Surf)%CpOld1     = 1200 ! SpecHeatSolidPCM
   SurfaceFD(Surf)%CpOld2     = 1200 ! SpecHeatSolidPCM
   SurfaceFD(Surf)%Cp_node    = 1200 ! SpecHeatSolidPCM
   SurfaceFD(Surf)%Cp1_node   = 1200 ! SpecHeatSolidPCM
   SurfaceFD(Surf)%Cp2_node   = 1200 ! SpecHeatSolidPCM
   SurfaceFD(Surf)%PhaseChangeDeltaT    = 1
   SurfaceFD(Surf)%PhaseChangeDeltaTOld = 1
   SurfaceFD(Surf)%PhaseChangeTransition = 0
   SurfaceFD(Surf)%PhaseChangeTransition = 0 
   SurfaceFD(Surf)%PhaseChangeState = 2
   SurfaceFD(Surf)%PhaseChangeStateold = 2
   SurfaceFD(Surf)%PhaseChangeStateoldold = 2
   SurfaceFD(Surf)% PhaseChangeTemperatureReverse = 50
!VE END 


    !Initialize the allocated arrays.
    SurfaceFD(Surf)%T              = TempInitValue
    SurfaceFD(Surf)%TOld           = TempInitValue
    SurfaceFD(Surf)%TT             = TempInitValue
    SurfaceFD(Surf)%Rhov           = RhovInitValue
    SurfaceFD(Surf)%RhovOld        = RhovInitValue
    SurfaceFD(Surf)%RhoT           = RhovInitValue
    SurfaceFD(Surf)%TD             = TempInitValue
    SurfaceFD(Surf)%TDT            = TempInitValue
    SurfaceFD(Surf)%TDTLast        = TempInitValue
    SurfaceFD(Surf)%TDOld          = TempInitValue
    SurfaceFD(Surf)%TDreport       = TempInitValue
    SurfaceFD(Surf)%RH             = 0.0d0
    SurfaceFD(Surf)%RHreport       = 0.0d0
    SurfaceFD(Surf)%EnthOld        = EnthInitValue
    SurfaceFD(Surf)%EnthNew        = EnthInitValue
    SurfaceFD(Surf)%EnthLast       = EnthInitValue
  END DO


  DO SurfNum=1,TotSurfaces
    IF (.not. Surface(SurfNum)%HeatTransSurf) CYCLE
    IF (Surface(SurfNum)%Class == SurfaceClass_Window) CYCLE
    IF (Surface(SurfNum)%HeatTransferAlgorithm /= HeatTransferModel_CondFD) CYCLE
!VE START
    CALL SetupOutputVariable('CondFD Surface Heat Flux [W/m2]', QFluxZoneToInSurf(SurfNum), &
                             'Zone','State',TRIM(Surface(SurfNum)%Name)) !This is a renamed copy of CondFD Inside Heat Flux to Surface. 
							 !This output is more useful than the "Surface Average Face Conduction Heat Transfer Rate Per Area that replaced it,
							 !due to it only reporting on CondFD surfaces.  
!Som Shrestha "Compare the heat flux through the walls to the conditioned space using the output variable �CondFD Inside Heat Flux to Surface�.
! The reporting variable �CondFD Inside Surface Heat Flux� has an issue therefore the new variable was added to resolve it." 
!VE END
    CALL SetupOutputVariable('CondFD Inner Solver Loop Iteration Count [ ]', SurfaceFD(SurfNum)%GSloopCounter, &
                             'Zone','Sum',Surface(SurfNum)%Name)



    TotNodes = ConstructFD(Surface(SurfNum)%Construction)%TotNodes  ! Full size nodes, start with outside face.
    DO Lay = 1,TotNodes +1  ! include inside face node
      CALL SetupOutputVariable('CondFD Surface Temperature Node '//TRIM(TrimSigDigits(Lay))//' [C]',&
           SurfaceFD(SurfNum)%TDreport(Lay),  &
          'Zone','State', Surface(SurfNum)%Name)
!VE START        		       
      CALL SetupOutputVariable('CondFD Surface Phase Change State Node '//TRIM(TrimSigDigits(Lay))//' [ ]',&
           SurfaceFD(SurfNum)%PhaseChangeState(Lay),  &
          'Zone','State', Surface(SurfNum)%Name)  
!VE END

!VE-2016 DEV START   
! The final work on this code is to make some more useful output reporting. 
! New Output set 1: averages the phase change state across the surface nodes and averaged for the zone and building.  
! Example of desired output varribles below:
!      CALL SetupOutputVariable('CondFD Surface Phase Change State Surface  [ ]',&
!           SurfaceFD(SurfNum)%PhaseChangeState,  &
!          'Zone','State', Surface(SurfNum)%Name)
!
!      CALL SetupOutputVariable('CondFD Surface Phase Change State Zone  [ ]',&
!           SurfaceFD(SurfNum)%PhaseChangeState,  &
!          'Zone','State', Surface(SurfNum)%Name) 

!      CALL SetupOutputVariable('CondFD Surface Phase Change State Building  [ ]',&
!           SurfaceFD(SurfNum)%PhaseChangeState(Lay),  &
!          'Building','State', Surface(SurfNum)%Name) 
! 
! New Output set 2: is to have the PCM Heat Absorbtion or Rejection Enthalpy value for the Facility, Zone, Surface level.
!The PCM Heat Absorbtion Enthalpy [] value is the time series latent heat of fusion + liquid state sebsable heat.
!The PCM Heat Rejection Enthalpy []  value is the time series latent heat of solidificaiton + solid state sebsable heat.
!
!Internal varribles that should hold the correct value during routines						 
! REAL(r64)         :: EnthalpyM ! Melting Enthalpy at a particular temperature
! REAL(r64)         :: EnthalpyF ! Freezing Enthalpy at a particular temperature   
! 
! Example of desired output varribles below:
!
! Surface Thermal Load Rate outputs:   
!            CALL SetupOutputVariable('Surface PCM Heat Absorption Enthalpy Rate [W]', EnthalpyM(I), &
!                                'System','Average',Surface(ZoneNum)%Name)
!
!             CALL SetupOutputVariable('Surface PCM Heat Rejection Enthalpy Rate [W]', EnthalpyF(I), &
!                                'System','Average',Surface(i)%Name)
!
! Zone Thermal Load Rate outputs:   
!            CALL SetupOutputVariable('Zone PCM Heat Absorption Enthalpy Rate [W]', EnthalpyM(I), &
!                                'System','Average',Zone(ZoneNum)%Name)
!
!             CALL SetupOutputVariable('Zone PCM Heat Rejection Enthalpy Rate [W]', EnthalpyF(I), &
!                                'System','Average',Zone(i)%Name)
! Facility Thermal Load Rate outputs:
!            CALL SetupOutputVariable('Facility PCM Heat Absorption Enthalpy Rate [W]', EnthalpyM(I), &
!                                'System','Average',Facility(ZoneNum)%Name)
! 
!             CALL SetupOutputVariable('Facility PCM Heat Rejection Enthalpy Rate [W]', EnthalpyF(I), &
!                                'System','Average',Facility(i)%Name)
!
! Surface Energy Consumption outputs:   
!            CALL SetupOutputVariable('Surface PCM Heat Absorption Enthalpy Energy [J]', EnthalpyM(I), &
!                               'System','Average',Surface(i)%Name)
! 
!           CALL SetupOutputVariable('Surface PCM Heat Rejection Enthalpy Energy [J]', EnthalpyF(I), &
!                             'System','Average',Surface(i)%Name)
! Zone Energy Consumption outputs:   
!            CALL SetupOutputVariable('Zone PCM Heat Absorption Enthalpy Energy [J]', EnthalpyM(I), &
!                               'System','Average',Zone(i)%Name)
! 
!           CALL SetupOutputVariable('Zone PCM Heat Rejection Enthalpy Energy [J]', EnthalpyF(I), &
!                             'System','Average',Zone(i)%Name)
!
! Facility Energy Consumption outputs:   
!            CALL SetupOutputVariable('Facility PCM Heat Absorption Enthalpy Energy [J]', EnthalpyM(I), &
!                               'System','Average',Facility(i)%Name)
! 
!           CALL SetupOutputVariable('Facility PCM Heat Rejection Enthalpy Energy [J]', EnthalpyF(I), &
!                             'System','Average',Facility(i)%Name)
!
!VE-2016 DEV END
    END DO

  ENDDO  ! End of the Surface Loop for Report Variable Setup

  CALL ReportFiniteDiffInits  ! Report the results from the Finite Diff Inits

  RETURN

END SUBROUTINE InitialInitHeatBalFiniteDiff

SUBROUTINE CalcHeatBalFiniteDiff(Surf,TempSurfInTmp,TempSurfOutTmp)

          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard J. Liesen
          !       DATE WRITTEN   Oct 2003
          !       MODIFIED       Aug 2006 by C O Pedersen to include implicit solution and variable properties with
          !                                material enthalpy added for Phase Change Materials.
          !                      Sept 2010 B. Griffith, remove allocate/deallocate, use structure variables
          !                      March 2011 P. Tabares, add relaxation factor and add surfIteration to
          !                                 update TD and TDT, correct interzone partition
          !                      May 2011  B. Griffith add logging and errors when inner GS loop does not converge
          !                      November 2011 P. Tabares fixed problems with adiabatic walls/massless walls and PCM stability problems

          !       RE-ENGINEERED  na

          ! PURPOSE OF THIS SUBROUTINE:
          ! this routine controls the calculation of the fluxes and temperatures using
          !      finite difference procedures for
          !      all building surface constructs.

          ! METHODOLOGY EMPLOYED:
          ! <description>

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
  USE General,         ONLY : RoundSigDigits
  USE DataHeatBalance, ONLY : CondFDRelaxFactor
  USE DataGlobals,     ONLY : KickOffSimulation
  USE DataSurfaces,    ONLY : HeatTransferModel_CondFD

  IMPLICIT NONE ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
  INTEGER,   INTENT(In)    :: Surf
  REAL(r64), INTENT(InOut) :: TempSurfInTmp       !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64), INTENT(InOut) :: TempSurfOutTmp      !Outside Surface Temperature of each Heat Transfer Surface

          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS:
          ! na

          ! DERIVED TYPE DEFINITIONS:
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:

  REAL(r64)  :: HMovInsul           !  Equiv H for TIM layer,  Comes with call to
                                                 ! EvalOutsideMovableInsulation
  INTEGER    :: RoughIndexMovInsul   ! roughness  Movable insulation
  REAL(r64)  :: AbsExt              ! exterior absorptivity  movable insulation

  INTEGER  :: I       !  Node number in construction
  INTEGER  :: J
  INTEGER  :: Lay
  INTEGER  :: ctr
  INTEGER  :: ConstrNum
  INTEGER  :: TotLayers
  INTEGER  :: TotNodes
  INTEGER  :: delt
  INTEGER  :: GSiter !  iteration counter for implicit repeat calculation
  REAL(r64) :: MaxDelTemp = 0.0d0
  INTEGER   :: NodeNum

  ConstrNum=Surface(surf)%Construction

  TotNodes = ConstructFD(ConstrNum)%TotNodes
  TotLayers = Construct(ConstrNum)%TotLayers

  TempSurfInTmp =0.0d0
  TempSurfOutTmp=0.0d0


  Delt = ConstructFD(ConstrNum)%DeltaTime    !   (seconds)
!VE START
 If(BeginEnvrnFlag)Then
    SurfaceFD(Surf)%TOld = 23.0d0
    SurfaceFD(Surf)%RhovOld = 0.0115d0
    SurfaceFD(Surf)%TDOld = 23.0d0
    SurfaceFD(Surf)%EnthOld = 1000.d0
    SurfaceFD(Surf)%T = 0.0
    SurfaceFD(Surf)%TT = 0.0
    SurfaceFD(Surf)%Rhov = 0.0
    SurfaceFD(Surf)%RhoT = 0.0
    SurfaceFD(Surf)%RH = 0.0
    SurfaceFD(Surf)%TDreport = 0.0
    SurfaceFD(Surf)%Enthreport = 0.0   
    SurfaceFD(Surf)%TD = 0.0
    SurfaceFD(Surf)%TDT = 0.0
    SurfaceFD(Surf)%TempLastStep = 0.0
    SurfaceFD(Surf)%TDTLast=0.0
    SurfaceFD(Surf)%EnthOld =0.0
    SurfaceFD(Surf)%EnthLast =0.0
    SurfaceFD(Surf)%EnthNew = 0.0
    SurfaceFD(Surf)%CpOld=1200 ! SpecHeatSolidPCM 
    SurfaceFD(Surf)%CpOld1=1200 ! SpecHeatSolidPCM
    SurfaceFD(Surf)%CpOld2=1200 ! SpecHeatSolidPCM
    SurfaceFD(Surf)%Cp_node=1200 ! SpecHeatSolidPCM 
    SurfaceFD(Surf)%Cp1_node=1200 ! SpecHeatSolidPCM
    SurfaceFD(Surf)%Cp2_node=1200 ! SpecHeatSolidPCM
    SurfaceFD(Surf)%PhaseChangeDeltaT=1
    SurfaceFD(Surf)%PhaseChangeDeltaTOld=1
    SurfaceFD(Surf)%PhaseChangeState=2
    SurfaceFD(Surf)%PhaseChangeStateold=2
    SurfaceFD(Surf)%PhaseChangeStateoldold=2
    SurfaceFD(Surf)%PhaseChangeTemperatureReverse=50
 End If
 SurfaceFD(Surf)%T = SurfaceFD(Surf)%TOld
 SurfaceFD(Surf)%Rhov = SurfaceFD(Surf)%RhovOld
 SurfaceFD(Surf)%TD = SurfaceFD(Surf)%TDOld
 SurfaceFD(Surf)%TDT = SurfaceFD(Surf)%TDOld
 SurfaceFD(Surf)%TempLastStep = SurfaceFD(Surf)%TDOld
 SurfaceFD(Surf)%TDTLast=SurfaceFD(Surf)%TDOld
 SurfaceFD(Surf)%EnthOld = SurfaceFD(Surf)%EnthOld
 SurfaceFD(Surf)%EnthNew =SurfaceFD(Surf)%EnthOld
 SurfaceFD(Surf)%EnthLast = SurfaceFD(Surf)%EnthOld
 SurfaceFD(Surf)%EnthLastStep       = SurfaceFD(Surf)%EnthOld
 SurfaceFD(Surf)%PhaseChangeDeltaTOld=SurfaceFD(Surf)%PhaseChangeDeltaT
 SurfaceFD(Surf)%CpOld=SurfaceFD(Surf)%Cp_node
 SurfaceFD(Surf)%CpOld1=SurfaceFD(Surf)%Cp1_node
 SurfaceFD(Surf)%CpOld2=SurfaceFD(Surf)%Cp2_node
!VE END 
  CALL EvalOutsideMovableInsulation(Surf,HMovInsul,RoughIndexMovInsul,AbsExt)
 ! Start stepping through the slab with time.
  DO J=1,NINT((TimeStepZone*SecInHour)/Delt)  !PT testing higher time steps

    DO GSiter = 1, MaxGSiter  !  Iterate implicit equations
      SurfaceFD(Surf)%TDTLast = SurfaceFD(Surf)%TDT    !  Save last iteration's TDT (New temperature) values
      SurfaceFD(Surf)%EnthLast = SurfaceFD(Surf)%EnthNew  ! Last iterations new enthalpy value

!  Original loop version
      I= 1   !  Node counter
      DO Lay = 1, TotLayers    ! Begin layer loop ...

        !For the exterior surface node with a convective boundary condition
        IF(I == 1 .and. Lay ==1)THEN
!VE START@ SurfaceFD(Surf)%CpOld
          CALL ExteriorBCEqns(Delt,I,Lay,Surf,SurfaceFD(Surf)%T, &
                                        SurfaceFD(Surf)%TT, &
                                        SurfaceFD(Surf)%Rhov, &
                                        SurfaceFD(Surf)%RhoT, &
                                        SurfaceFD(Surf)%RH, &
                                        SurfaceFD(Surf)%TD, &
                                        SurfaceFD(Surf)%TDT,&
                                        SurfaceFD(Surf)%EnthOld, &
                                        SurfaceFD(Surf)%EnthNew, &
                                          TotNodes,HMovInsul,  &                                         
                                          SurfaceFD(Surf)%CpOld, &
                                          SurfaceFD(Surf)%PhaseChangeDeltaT, SurfaceFD(Surf)%PhaseChangeTransition,  &
                                          SurfaceFD(Surf)%Cp_node, &
                                          SurfaceFD(Surf)%PhaseChangeState, &
                                          SurfaceFD(Surf)%PhaseChangeStateold, SurfaceFD(Surf)%PhaseChangeTransitionOld, &
                                          SurfaceFD(Surf)%PhaseChangeDeltaTOld, &
                                          SurfaceFD(Surf)%PhaseChangeStateoldold, &
                                          SurfaceFD(Surf)% PhaseChangeTemperatureReverse, Tc, TcOld, SurfaceFD(Surf)%EnthLastStep)       
!VE END      
        END IF

        !For the Layer Interior nodes.  Arrive here after exterior surface node or interface node

        IF(TotNodes .ne. 1) THEN

          DO Ctr=2,ConstructFD(ConstrNum)%NodeNumPoint(Lay)
            I=I+1
!VE START@   SurfaceFD(Surf)%CpOld
            CALL InteriorNodeEqns(Delt,I,Lay,Surf,SurfaceFD(Surf)%T, &
                                  SurfaceFD(Surf)%TT, &
                                  SurfaceFD(Surf)%Rhov, &
                                  SurfaceFD(Surf)%RhoT,&
                                  SurfaceFD(Surf)%RH, &
                                  SurfaceFD(Surf)%TD, &
                                  SurfaceFD(Surf)%TDT, &
                                  SurfaceFD(Surf)%EnthOld, &
                                    SurfaceFD(Surf)%EnthNew, &
                                    SurfaceFD(Surf)%CpOld, &
                                    SurfaceFD(Surf)%PhaseChangeDeltaT, SurfaceFD(Surf)%PhaseChangeTransition, &
                                    SurfaceFD(Surf)%Cp_node, &
                                          SurfaceFD(Surf)%PhaseChangeState, &
                                          SurfaceFD(Surf)%PhaseChangeStateold, SurfaceFD(Surf)%PhaseChangeTransitionOld,&
                                          SurfaceFD(Surf)%PhaseChangeDeltaTOld, SurfaceFD(Surf)%PhaseChangeStateoldold, &
                                          SurfaceFD(Surf)% PhaseChangeTemperatureReverse) 
!VE END  
          END DO
        END IF

        IF(Lay < TotLayers .and. TotNodes .ne. 1) THEN
          !Interface equations for 2 capactive materials
          I=I+1
!VE START@ SurfaceFD(Surf)%CpOld1
          CALL IntInterfaceNodeEqns(Delt,I,Lay,Surf,SurfaceFD(Surf)%T, &
                                   SurfaceFD(Surf)%TT, &
                                   SurfaceFD(Surf)%Rhov, &
                                   SurfaceFD(Surf)%RhoT, &
                                   SurfaceFD(Surf)%RH, &
                                   SurfaceFD(Surf)%TD, &
                                   SurfaceFD(Surf)%TDT, &
                                   SurfaceFD(Surf)%EnthOld, &
                                     SurfaceFD(Surf)%EnthNew,GSiter, &
                                     SurfaceFD(Surf)%CpOld1, &
                                     SurfaceFD(Surf)%CpOld2, &
                                     SurfaceFD(Surf)%PhaseChangeDeltaT, SurfaceFD(Surf)%PhaseChangeTransition, &
                                     SurfaceFD(Surf)%Cp1_node, &
                                     SurfaceFD(Surf)%Cp2_node, &
                                          SurfaceFD(Surf)%PhaseChangeState, &
                                          SurfaceFD(Surf)%PhaseChangeStateold, &
                                          SurfaceFD(Surf)%PhaseChangeStateoldold, &
                                          SurfaceFD(Surf)% PhaseChangeTemperatureReverse) 
!VE END 
        ELSE IF (Lay == TotLayers) THEN
          !For the Interior surface node with a convective boundary condition
          I=I+1
!VE START@ SurfaceFD(Surf)%CpOld 
          CALL InteriorBCEqns(Delt,I,Lay,Surf, &
                                   SurfaceFD(Surf)%T, &
                                   SurfaceFD(Surf)%TT, &
                                   SurfaceFD(Surf)%Rhov, &
                                   SurfaceFD(Surf)%RhoT, &
                                   SurfaceFD(Surf)%RH, &
                                   SurfaceFD(Surf)%TD, &
                                   SurfaceFD(Surf)%TDT, &
                                   SurfaceFD(Surf)%EnthOld, &
                                   SurfaceFD(Surf)%EnthNew, &
                                   SurfaceFD(Surf)%TDReport, &
                                     SurfaceFD(Surf)%CpOld, &
                                     SurfaceFD(Surf)%PhaseChangeDeltaT, &
                                     SurfaceFD(Surf)%Cp_node, &
                                          SurfaceFD(Surf)%PhaseChangeState, &
                                          SurfaceFD(Surf)%PhaseChangeStateold, &
                                          SurfaceFD(Surf)%PhaseChangeStateoldold, &
                                          SurfaceFD(Surf)% PhaseChangeTemperatureReverse,SurfaceFD(Surf)%PhaseChangeTransition )
!VE END
        END IF

      END DO    !The end of the layer loop


      IF (Gsiter .gt. 5) THEN
      !apply Relaxation factor for stability, use current (TDT) and previous (TDTLast) iteration temperature values
      !to obtain the actual temperature that is going to be used for next iteration. THis would mostly happen with PCM
        SurfaceFD(Surf)%TDT = SurfaceFD(Surf)%TDTLast+ (SurfaceFD(Surf)%TDT-SurfaceFD(Surf)%TDTLast) * 0.5d0
      ENDIF

      IF (Gsiter .gt. 10) THEN
      !apply Relaxation factor for stability, use current (TDT) and previous (TDTLast) iteration temperature values
      !to obtain the actual temperature that is going to be used for next iteration. THis would mostly happen with PCM
        SurfaceFD(Surf)%TDT = SurfaceFD(Surf)%TDTLast+ (SurfaceFD(Surf)%TDT-SurfaceFD(Surf)%TDTLast) * 0.25d0
      ENDIF

      IF (Gsiter .gt. 15) THEN
      !apply Relaxation factor for stability, use current (TDT) and previous (TDTLast) iteration temperature values
      !to obtain the actual temperature that is going to be used for next iteration. THis would mostly happen with PCM
        SurfaceFD(Surf)%TDT = SurfaceFD(Surf)%TDTLast+ (SurfaceFD(Surf)%TDT-SurfaceFD(Surf)%TDTLast) * 0.10d0
      ENDIF

      ! the following could blow up when all the node temps sum to less than 1.0.  seems poorly formulated for temperature in C.
        !PT delete one zero and decrese number of minimum iterations, from 3 (which actually requires 4 iterations) to 2.

      IF (Gsiter .gt. 2  .and.ABS(SUM(SurfaceFD(Surf)%TDT-SurfaceFD(Surf)%TDTLast)/SUM(SurfaceFD(Surf)%TDT)) < 0.00001d0 )  EXIT
      !SurfaceFD(Surf)%GSloopCounter = Gsiter  !PT moved out of GSloop so it can actually count all iterations

!feb2012 the following could blow up when all the node temps sum to less than 1.0.  seems poorly formulated for temperature in C.
!feb2012      IF (Gsiter .gt. 3  .and.ABS(SUM(SurfaceFD(Surf)%TDT-SurfaceFD(Surf)%TDTLast)/SUM(SurfaceFD(Surf)%TDT)) < 0.000001d0 )  EXIT
!feb2012      SurfaceFD(Surf)%GSloopCounter = Gsiter
!      IF ((GSiter == MaxGSiter) .AND. (SolutionAlgo /= UseCondFDSimple)) THEN ! didn't ever converge
!        IF (.NOT. WarmupFlag .AND. (.NOT. KickOffSimulation)) THEN
!          ErrCount=ErrCount+1
!          ErrorSignal = ABS(SUM(SurfaceFD(Surf)%TDT-SurfaceFD(Surf)%TDTLast)/SUM(SurfaceFD(Surf)%TDT))
!          IF (ErrCount < 10) THEN
!            CALL ShowWarningError('ConductionFiniteDifference inner iteration loop did not converge for surface named ='// &
!                          TRIM(Surface(Surf)%Name) // &
!                          ', with error signal ='//TRIM(RoundSigDigits(ErrorSignal, 8)) // &
!                          ' vs criteria of 0.000001')
!            CALL ShowContinueErrorTimeStamp(' ')
!          ELSE
!            CALL ShowRecurringWarningErrorAtEnd('ConductionFiniteDifference convergence problem continues for surface named ='// &
!                                                TRIM(Surface(Surf)%Name) , &
!                                               SurfaceFD(Surf)%GSloopErrorCount,ReportMaxOf=ErrorSignal,ReportMinOf=ErrorSignal,  &
!                                               ReportMaxUnits='[ ]',ReportMinUnits='[ ]')
!          ENDIF
!
!        ENDIF
!
!      ENDIF

    END DO ! End of Gauss Seidell iteration loop

    SurfaceFD(Surf)%GSloopCounter = Gsiter   !outputs GSloop iterations, useful for pinpointing stability issues with condFD
    IF (CondFDRelaxFactor/=1.0d0) THEN
     !apply Relaxation factor for stability, use current (TDT) and previous (TDreport) temperature values
     !   to obtain the actual temperature that is going to be exported/use
      SurfaceFD(Surf)%TDT = SurfaceFD(Surf)%TDreport+ (SurfaceFD(Surf)%TDT-SurfaceFD(Surf)%TDreport) * CondFDRelaxFactor
      SurfaceFD(Surf)%EnthOld = SurfaceFD(Surf)%EnthNew
    ENDIF

!VE START
     SurfaceFD(Surf)%CpOld=SurfaceFD(Surf)%Cp_node
     SurfaceFD(Surf)%CpOld1=SurfaceFD(Surf)%Cp1_node
     SurfaceFD(Surf)%CpOld2=SurfaceFD(Surf)%Cp2_node

     I= 1   !  Node counter
     Do I = 1,(TotNodes+1)
        !When the phase change process reverses its direction while melting or freezing (without completing its phase 
        !to either liquid or solid), the temperature at which it changes its direction is saved 
        !in the variable  PhaseChangeTemperatureReverse, and this variable will hold the value of the temperature until
        !the next reverse in the process takes place.
        If ((SurfaceFD(Surf)%PhaseChangeStateold(I) == 1 .and. SurfaceFD(Surf)%PhaseChangeState(I) == 0)) Then
            SurfaceFD(Surf)% PhaseChangeTemperatureReverse(I) = SurfaceFD(Surf)%TDT(I)
        ElseIf ((SurfaceFD(Surf)%PhaseChangeStateold(I) == 0 .and. SurfaceFD(Surf)%PhaseChangeState(I) == 1 )) Then
            SurfaceFD(Surf) % PhaseChangeTemperatureReverse(I) = SurfaceFD(Surf)%TDT(I)
        ELSE If ((SurfaceFD(Surf)%PhaseChangeStateold(I) == -1 .and. SurfaceFD(Surf)%PhaseChangeState(I) == 0)) Then
            SurfaceFD(Surf)% PhaseChangeTemperatureReverse(I) = SurfaceFD(Surf)%TDT(I)
        ElseIf ((SurfaceFD(Surf)%PhaseChangeStateold(I) == 0 .and. SurfaceFD(Surf)%PhaseChangeState(I) == -1)) Then
            SurfaceFD(Surf)% PhaseChangeTemperatureReverse(I) = SurfaceFD(Surf)%TDT(I)            
        End If    
     End Do

     SurfaceFD(Surf)%PhaseChangeDeltaTOld=SurfaceFD(Surf)%PhaseChangeDeltaT
     SurfaceFD(Surf)%PhaseChangeStateoldold=SurfaceFD(Surf)%PhaseChangeStateold
     SurfaceFD(Surf)%PhaseChangeStateold=SurfaceFD(Surf)%PhaseChangeState
     SurfaceFD(Surf)%PhaseChangeDeltaT=SurfaceFD(Surf)%TD - SurfaceFD(Surf)%TDT 
     SurfaceFD(Surf)%PhaseChangeTransitionOld= SurfaceFD(Surf)%PhaseChangeTransition
     
     TcOld =Tc
 
     ! If the value of PhaseChangeDeltaT is positive then the PCM is on the freezing curve (heat rejection).
     ! If the value of PhaseChangeDeltaT is negative then PCM is on the melting curve (heat absorption). 
                                                                 
     I= 1   !  Node counter
     Do I = 1,(TotNodes+1)
        If (SurfaceFD(Surf)%PhaseChangeDeltaT(I) == 0) Then
            SurfaceFD(Surf)%PhaseChangeDeltaT(I) = SurfaceFD(Surf)%PhaseChangeDeltaTOld(I)
        End If        
     End Do
     
   SurfaceFD(Surf)%TempLastStep = SurfaceFD(Surf)%TD
   SurfaceFD(Surf)%TD = SurfaceFD(Surf)%TDT
   SurfaceFD(Surf)%EnthLastStep = SurfaceFD(Surf)%EnthOld
   SurfaceFD(Surf)%EnthOld = SurfaceFD(Surf)%EnthNew
!VE END

 END DO     !The end of the Time Loop   !PT solving time steps

  TempSurfOutTmp = SurfaceFD(Surf)%TDT(1)
  TempSurfInTmp  = SurfaceFD(Surf)%TDT(TotNodes+1)
  RhoVaporSurfIn(surf) = 0.0d0

  ! determine largest change in node temps
  MaxDelTemp      = 0.0d0
  DO NodeNum = 1, TotNodes+1   !need to consider all nodes
    MaxDelTemp = MAX(ABS(SurfaceFD(Surf)%TDT(NodeNum) - SurfaceFD(Surf)%TDreport(NodeNum)), MaxDelTemp)
  ENDDO
  SurfaceFD(Surf)%MaxNodeDelTemp = MaxDelTemp
!  SurfaceFD(Surf)%TDOld          = SurfaceFD(Surf)%TDT
  SurfaceFD(Surf)%TDreport       = SurfaceFD(Surf)%TDT
  SurfaceFD(Surf)%EnthOld        = SurfaceFD(Surf)%EnthNew

 RETURN


End SUBROUTINE CalcHeatBalFiniteDiff


! Beginning of Reporting subroutines
! *****************************************************************************

SUBROUTINE UpdateMoistureBalanceFD(Surf)

    ! SUBROUTINE INFORMATION:
    !   Authors:        Richard Liesen
    !   Date writtenn:  November, 2003
    !   Modified:       na
    !   Re-engineered:  na

    ! PURPOSE OF THIS SUBROUTINE:
    ! Update the data structures after the inside surface heat balance has converged.

    ! METHODOLOGY EMPLOYED:
    !

    ! USE STATEMENTS:

    IMPLICIT NONE
    Integer, INTENT(IN)  :: Surf ! Surface number

    INTEGER   :: ConstrNum

    ConstrNum = Surface(surf)%Construction
    SurfaceFD(Surf)%TOld = SurfaceFD(Surf)%T
    SurfaceFD(Surf)%RhovOld = SurfaceFD(Surf)%Rhov
    SurfaceFD(Surf)%TDOld = SurfaceFD(Surf)%TDreport

RETURN

END SUBROUTINE UpdateMoistureBalanceFD

SUBROUTINE ReportFiniteDiffInits

          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard Liesen
          !       DATE WRITTEN   November 2003
          !       MODIFIED       B. Griffith, May 2011 add reporting of node x locations
          !       RE-ENGINEERED  na

          ! PURPOSE OF THIS SUBROUTINE:
          ! This routine gives a detailed report to the user about
          ! the initializations for the Fintie Difference calculations
          ! of each construction.

          ! METHODOLOGY EMPLOYED:
          ! na

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
  USE General, ONLY: ScanForReports, RoundSigDigits
  USE DataHeatBalance, ONLY: MaxAllowedDelTempCondFD, CondFDRelaxFactorInput, HeatTransferAlgosUsed

  IMPLICIT NONE    ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
          ! na

          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS
          ! na

          ! DERIVED TYPE DEFINITIONS
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
  LOGICAL :: DoReport
  CHARACTER(len=MaxNameLength) :: InodesChar
  INTEGER :: ThisNum
  INTEGER :: Layer
  INTEGER :: OutwardMatLayerNum
  INTEGER :: layerNode
  INTEGER :: Inodes

  Write(OutputFileInits,'(A)') '! <ConductionFiniteDifference HeatBalanceSettings>,Scheme Type,Space Discretization Constant,'//  &
     'Relaxation Factor,Inside Face Surface Temperature Convergence Criteria'
  Write(OutputFileInits,'(A)') ' ConductionFiniteDifference HeatBalanceSettings,'//  &
     trim(cCondFDSchemeType(CondFDSchemeType))//','//  &
     trim(RoundSigDigits(SpaceDescritConstant,2))//','//trim(RoundSigDigits(CondFDRelaxFactorInput,2))//','//  &
     trim(RoundSigDigits(MaxAllowedDelTempCondFD,4))
  CALL ScanForReports('Constructions',DoReport,'Constructions')

  IF (DoReport) THEN

!                                      Write Descriptions
    Write(OutputFileInits,'(A)') '! <Construction CondFD>,Construction Name,Index,#Layers,#Nodes,Time Step {hours}'
    Write(OutputFileInits,'(A)') '! <Material CondFD Summary>,Material Name,Thickness {m},#Layer Elements,Layer Delta X,'//  &
                             'Layer Alpha*Delt/Delx**2,Layer Moisture Stability'
  !HT Algo issue
    IF (ANY(HeatTransferAlgosUsed == UseCondFD))  &
       WRITE(OutputFileInits,'(A)') '! <ConductionFiniteDifference Node>,Node Identifier, '// &
        ' Node Distance From Outside Face {m}, Construction Name, Outward Material Name (or Face), Inward Material Name (or Face)'
    DO ThisNum=1,TotConstructs

      IF (Construct(ThisNum)%TypeIsWindow) CYCLE
      IF (Construct(ThisNum)%TypeIsIRT) CYCLE

      Write(OutputFileInits,700) TRIM(Construct(ThisNum)%Name),trim(RoundSigDigits(ThisNum)),  &
          trim(RoundSigDigits(Construct(ThisNum)%TotLayers)),  &
          trim(RoundSigDigits(Int(ConstructFD(ThisNum)%TotNodes+1))),  &
          trim(RoundSigDigits(ConstructFD(ThisNum)%DeltaTime/SecInHour,6))
!
 700  FORMAT(' Construction CondFD,',A,2(',',A),',',A,',',A)
 701  FORMAT(' Material CondFD Summary,',A,',',A,',',A,',',A,',',A,',',A)
 702  FORMAT(' ConductionFiniteDifference Node,', A, ',', A, ',', A, ',', A, ',', A)


      DO Layer=1,Construct(ThisNum)%TotLayers
            Write(OutputFileInits,701) TRIM(ConstructFD(ThisNum)%Name(Layer)),  &
                                       trim(RoundSigDigits(ConstructFD(ThisNum)%Thickness(Layer),4)),      &
                                       trim(RoundSigDigits(ConstructFD(ThisNum)%NodeNumPoint(Layer))),  &
                                       trim(RoundSigDigits(ConstructFD(ThisNum)%Delx(Layer),8)),  &
                                       trim(RoundSigDigits(ConstructFD(ThisNum)%TempStability(Layer),8)),  &
                                       trim(RoundSigDigits(ConstructFD(ThisNum)%MoistStability(Layer),8))
      ENDDO

      !now list each CondFD Node with its X distance from outside face in m along with other identifiers
      Inodes = 0

      DO Layer=1,Construct(ThisNum)%TotLayers
        OutwardMatLayerNum = Layer - 1
        DO layerNode = 1, ConstructFD(ThisNum)%NodeNumPoint(Layer)
          Inodes = Inodes + 1
          WRITE(InodesChar,*)Inodes
          IF (Inodes == 1) THEN
            WRITE(OutputFileInits,702) TRIM('Node #'//TRIM(ADJUSTL(InodesChar))), &
                                     TRIM(RoundSigDigits(ConstructFD(ThisNum)%NodeXlocation(Inodes), 8)), &
                                     TRIM(Construct(ThisNum)%Name) ,          &
                                     TRIM('Surface Outside Face'),          &
                                     TRIM(ConstructFD(ThisNum)%Name(Layer))

          ELSEIF (layerNode== 1 ) THEN

            IF ( OutwardMatLayerNum > 0 .AND. OutwardMatLayerNum <= Construct(ThisNum)%TotLayers ) THEN
               WRITE(OutputFileInits,702) TRIM('Node #'//TRIM(ADJUSTL(InodesChar))), &
                                     TRIM(RoundSigDigits(ConstructFD(ThisNum)%NodeXlocation(Inodes), 8)), &
                                     TRIM(Construct(ThisNum)%Name) ,          &
                                     TRIM(ConstructFD(ThisNum)%Name(OutwardMatLayerNum)), &
                                     TRIM(ConstructFD(ThisNum)%Name(Layer))

            ENDIF
          ELSEIF (layerNode >1) THEN
            OutwardMatLayerNum = Layer
            WRITE(OutputFileInits,702) TRIM('Node #'//TRIM(ADJUSTL(InodesChar))), &
                                     TRIM(RoundSigDigits(ConstructFD(ThisNum)%NodeXlocation(Inodes), 8)), &
                                     TRIM(Construct(ThisNum)%Name) ,          &
                                     TRIM(ConstructFD(ThisNum)%Name(OutwardMatLayerNum)), &
                                     TRIM(ConstructFD(ThisNum)%Name(Layer))
          ENDIF

          ENDDO
        ENDDO

        Layer = Construct(ThisNum)%TotLayers
        Inodes = Inodes + 1
        WRITE(InodesChar,*)Inodes
        WRITE(OutputFileInits,702) TRIM('Node #'//TRIM(ADJUSTL(InodesChar))), &
                                   TRIM(RoundSigDigits(ConstructFD(ThisNum)%NodeXlocation(Inodes), 8)), &
                                   TRIM(Construct(ThisNum)%Name) ,          &
                                   TRIM(ConstructFD(ThisNum)%Name(Layer)), &
                                   TRIM('Surface Inside Face')

    ENDDO

  ENDIF

  RETURN

END SUBROUTINE ReportFiniteDiffInits

! Utility Interpolation Function for the Module
!******************************************************************************
REAL(r64) Function terpld(N,a,x1,nind,ndep)
    !
    !author:c. o. pedersen
    !
    !purpose:
    !   this function performs a linear interpolation
    !     on a two dimensional array containing both
    !     dependent and independent variables.



    !inputs:
    !  a = two dimensional array
    !  nind=column containing independent variable
    !  ndep=column containing the dependent variable
    !   x1 = specific independent variable value for which
    !      interpolated output is wanted
    !outputs:
    !    the value of dependent variable corresponding
    !       to x1
    !    routine returns first or last dependent variable
    !      for out of range x1.
    !
     INTEGER, intent (IN)  :: N
     REAL(r64), DIMENSION(N,2),intent (IN)     :: a
     INTEGER, intent (IN)   :: nind
     INTEGER, intent (IN)   :: ndep
     REAL(r64), intent (IN)     :: x1
     INTEGER :: npts,first,last,i1,i2,i,irange
     INTEGER, DIMENSION(2) :: MaxLocArray
     REAL(r64) ::  fract

     npts = size(a,1)
     first=lbound(a,1)
     MaxLocArray=MaxLoc(a,1)
     last = MaxLocArray(1)
     IF ( npts ==1 .or. x1 <= a(first,nind) )then
       terpld=a(first,ndep)
     ELSEIF ( x1>= a(last,nind))then
       terpld=a(last,ndep)
     ELSE
       i1=first
       i2=last
       DO while ((i2-i1) > 1)
         irange=i2-i1
         i=i1+irange/2
         IF ( x1 < a(i,nind)) then
           i2=i
         ELSE
           i1=i
         END IF
      End DO
      i=i2
      fract=(x1-a(i-1,nind))/(a(i,nind)-a(i-1,nind))
      terpld=a(i-1,ndep)+fract*(a(i,ndep)-a(i-1,ndep))
    END IF
END Function

! Equation Types of the Module
!******************************************************************************
!VE START@ CpOld
SUBROUTINE ExteriorBCEqns(Delt,I,Lay,Surf,T,TT,Rhov,RhoT,RH,TD,TDT,EnthOld,EnthNew,TotNodes,HMovInsul, &
                            CpOld,PhaseChangeDeltaT,PhaseChangeTransition, Cp_node,PhaseChangeState,PhaseChangeStateold, PhaseChangeTransitionOld, &
                            PhaseChangeDeltaTOld,PhaseChangeStateoldold,Tr, Tc ,TcOld, EnthLastStep) 
! VE END

          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard Liesen
          !       DATE WRITTEN   November, 2003
          !       MODIFIED       B. Griffith 2010, fix adiabatic and other side surfaces
          !                      May 2011, B. Griffith, P. Tabares
          !                      November 2011 P. Tabares fixed problems with adiabatic walls/massless walls
          !                      November 2011 P. Tabares fixed problems PCM stability problems
		  !                      2013-2016, NRGsim Inc., added  Material Property Phase Change Hysteresis Routines.
          !       RE-ENGINEERED  Curtis Pedersen 2006

          ! PURPOSE OF THIS SUBROUTINE:
          ! <description>

          ! METHODOLOGY EMPLOYED:
          ! <description>

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
  USE DataSurfaces,          ONLY : OtherSideCondModeledExt, OSCM, HeatTransferModel_CondFD
  USE DataHeatBalSurface  ,  ONLY : QdotRadOutRepPerArea, QdotRadOutRep, QRadOutReport
  IMPLICIT NONE ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
  INTEGER, INTENT(IN)  :: Delt  ! Time Increment
  INTEGER, INTENT(IN)  :: I     ! Node Index
  INTEGER, INTENT(IN)  :: Lay   ! Layer Number for Construction
  INTEGER, INTENT(IN)  :: Surf  ! Surface number
  REAL(r64),DIMENSION(:), INTENT(In)    :: T     !Old node Temperature in MFD finite difference solution
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TT    !New node Temperature in MFD finite difference solution.
  REAL(r64),DIMENSION(:), INTENT(In)    :: Rhov  !MFD Nodal Vapor Density[kg/m3] and is the old or last time step result.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RhoT  !MFD vapor density for the new time step.
  REAL(r64),DIMENSION(:), INTENT(In)    :: TD    !The old dry Temperature at each node for the CondFD algorithm..
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TDT   !The current or new Temperature at each node location for the CondFD solution..
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RH    !Nodal relative humidity
  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthOld    ! Old Nodal enthalpy
  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthNew    ! New Nodal enthalpy
  INTEGER, INTENT(IN)  :: TotNodes !  Total nodes in layer
  REAL(r64), INTENT(IN) :: HMovInsul  !  Conductance of movable(transparent) insulation.
!VE START
  REAL(r64),Dimension(:), Intent(In)    :: EnthLastStep      
  REAL(r64), Intent(InOut)    :: Tc
  REAL(r64), Intent(In)    :: TcOld
  REAL(r64),Dimension(100)              :: EnthalpyF ! Freezing Enthalpy at a particular temperature 
  REAL(r64),Dimension(100)              :: EnthalpyM ! Melting Enthalpy at a particular temperature    
  REAL(r64), Dimension(100)             :: EnthRev
  REAL(r64),Dimension(:), Intent(InOut) :: CpOld      ! Old Specific Heat of the node, used only in case of PCM
  Real(r64),Dimension(:), Intent(In)    :: PhaseChangeDeltaT 
  INTEGER,Dimension(:), Intent(InOut)   :: PhaseChangeTransition
  REAL(r64),Dimension(:), Intent(InOut) :: Cp_node    ! Nodal Specific Heat
  Integer,Dimension(:), Intent(InOut)    :: PhaseChangeState !-2=Liquid, -1=Melting, 0=Transition, 1=Freezing, 2=Crystallized
  Integer,Dimension(:), Intent(InOut)    :: PhaseChangeStateold
  Real(r64),Dimension(:), Intent(In)     :: PhaseChangeDeltaTOld
  Integer,Dimension(:), Intent(InOut)    :: PhaseChangeStateoldold
  Integer,Dimension(:), Intent(In)       :: PhaseChangeTransitionold
  REAL(r64),Dimension(:), Intent(In)     :: Tr !  PhaseChangeTemperatureReverse
  REAL(r64)                              :: DeltaH
!VE END
          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS:
          ! na

          ! DERIVED TYPE DEFINITIONS:
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
  REAL(r64) :: QRadSWOutFD   !Short wave radiation absorbed on outside of opaque surface
  REAL(r64) :: Delx
  INTEGER   :: ConstrNum
  INTEGER   :: MatLay
  INTEGER   :: IndVarCol
  INTEGER   :: DepVarCol
  REAL(r64) :: hconvo
  REAL(r64) :: kt  ! temperature dependent thermal conductivity,  kt=ko +kt1(T-20)
  REAL(r64) :: kto  ! Base 20C thermal conductivity
  REAL(r64) :: kt1 ! Thermal conductivity gradient coefficient where: kt=ko +kt1(T-20)
  REAL(r64) :: Cpo ! Specific heat from idf
  REAL(r64) :: Cp  ! specific heat modified if PCM, otherwise equal to Cpo
  REAL(r64) :: RhoS

  REAL(r64) :: Toa
  REAL(r64) :: Rhovo
  REAL(r64) :: hmasso

  REAL(r64) :: hgnd
  REAL(r64) :: hrad
  REAL(r64) :: hsky
  REAL(r64) :: Tgnd
  REAL(r64) :: Tsky
  REAL(r64) :: Tia
  REAL(r64) :: SigmaRLoc
  REAL(r64) :: SigmaCLoc
  REAL(r64) :: Rlayer
  REAL(r64) :: QNetSurfFromOutside  !  Combined outside surface net heat transfer terms
  REAL(r64) :: TInsulOut  ! Temperature of outisde face of Outside Insulation
  REAL(r64) :: QRadSWOutMvInsulFD  ! SW radiation at outside of Movable Insulation
  INTEGER   :: LayIn  ! layer number for call to interior eqs
  INTEGER   :: NodeIn ! node number "I" for call to interior eqs
!VE START
  REAL(r64)         :: TempTlowPCM
  REAL(r64)         :: TempThighPCM
  REAL(r64)         :: TempTlowPCF
  REAL(r64)         :: TempThighPCF
  REAL(r64)         :: SpecHeatSolidPCM
  REAL(r64)         :: SpecHeatLiquidPCM
  REAL(r64)         :: SpecHeatTransition 
  REAL(r64)         :: Tau1
  REAL(r64)         :: Tau2
  !*****************************************************************************
  ! These are variables that explicitly hold the freezing and melting curve 
  ! properties and are used in the transition region only
  REAL(r64)         :: Tau1M ! Melting Region Low
  REAL(r64)         :: Tau2M ! Melting Region High
  REAL(r64)         :: Tau1F ! Freezing Region Low
  REAL(r64)         :: Tau2F ! Freezing Region High
  REAL(r64)         :: DeltaHM ! Latent heat of Melting
  REAL(r64)         :: DeltaHF ! Latent heat of Freezing
!********************************************************************************
!VE END
  ConstrNum=Surface(surf)%Construction

  !Boundary Conditions from Simulation for Exterior
  hconvo = HConvExtFD(surf)
  hmasso = HMassConvExtFD(surf)

  hrad = HAirFD(surf)
  hsky = HSkyFD(surf)
  hgnd = HGrndFD(surf)

  Toa = TempOutsideAirFD(surf)
  rhovo = RhoVaporAirOut(surf)
  Tgnd = TempOutsideAirFD(surf)
  IF (Surface(Surf)%ExtBoundCond == OtherSideCondModeledExt) THEN
   !CR8046 switch modeled rad temp for sky temp.
    TSky = OSCM(Surface(Surf)%OSCMPtr)%TRad
    QRadSWOutFD = 0.0D0 ! eliminate incident shortwave on underlying surface

  ELSE
  !Set the external conditions to local variables
    QRadSWOutFD = QRadSWOutAbs(surf)
    QRadSWOutMvInsulFD = QRadSWOutMvIns(Surf)
    TSky = SkyTemp
  ENDIF
  Tia = Mat(Surface(Surf)%Zone)
  SigmaRLoc=SigmaR(ConstrNum)
  SigmaCLoc=SigmaC(ConstrNum)

  MatLay = Construct(ConstrNum)%LayerPoint(Lay)
!VE START
  TcM = Material(MatLay)%Tm
  Tau1 = Material(MatLay)%Tau1
  Tau2 = Material(MatLay)%Tau2
  TempTlowPCM       = TcM-Tau1        ! Temperature at which Phase Change process starts
  TempThighPCM      = TcM+Tau2        ! Temperature at which Phase Change process ends 
  Material(MatLay)%TempLowPCM = TempTlowPCM            
  Material(MatLay)%TempHighPCM= TempThighPCM
  TcF = Material(MatLay)%Tf
  Tau1F = Material(MatLay)%Tau1Prime
  Tau2F = Material(MatLay)%Tau2Prime
  TempTlowPCF       = TcF-Tau1F        ! Temperature at which Phase Change process starts
  TempThighPCF      = TcF+Tau2F        ! Temperature at which Phase Change process ends         
  Material(MatLay)%TempLowPCF = TempTlowPCF            
  Material(MatLay)%TempHighPCF= TempThighPCF
    
  SpecHeatSolidPCM  = Material(MatLay)%CpSolid
  SpecHeatLiquidPCM = Material(MatLay)%CpLiquid
  SpecHeatTransition = (SpecHeatSolidPCM+SpecHeatLiquidPCM)/2
  DeltaHM = Material(MatLay)%DeltaHF
  DeltaHF = Material(MatLay)%DeltaHS
  Tau1M = Material(MatLay)%Tau1
  Tau2M = Material(MatLay)%Tau2
  Tau1F = Material(MatLay)%Tau1Prime
  Tau2F = Material(MatLay)%Tau2Prime
 !VE END
  IF(Surface(Surf)%ExtBoundCond == Ground .or. IsRain)THEN
    TDT(I) = Toa
    TT(I) = Toa
    RhoT(I)= rhovo
  ELSEIF (Surface(Surf)%ExtBoundCond > 0) THEN
   ! this is actually the inside face of another surface, or maybe this same surface if adiabatic
   ! switch around arguments for the other surf and call routines as for interior side BC from opposite face

    LayIn = Construct(Surface(Surface(Surf)%ExtBoundCond)%Construction)%TotLayers
    nodeIn = ConstructFD(Surface(Surface(Surf)%ExtBoundCond)%Construction)%TotNodes + 1

    IF (Surface(Surf)%ExtBoundCond == surf) THEN   !adiabatic surface, PT addded since it is not the same as interzone wall
                                                   ! as Outside Boundary Condition Object can be left blank.
!VE START@ SurfaceFD(Surf)%CpOld
      CALL InteriorBCEqns(Delt,nodeIn,LayIn,Surf,SurfaceFD(Surf)%T, &
                                          SurfaceFD(Surf)%TT, &
                                          SurfaceFD(Surf)%Rhov, &
                                          SurfaceFD(Surf)%RhoT, &
                                          SurfaceFD(Surf)%RH, &
                                          SurfaceFD(Surf)%TD, &
                                          SurfaceFD(Surf)%TDT, &
                                          SurfaceFD(Surf)%EnthOld, &
                                          SurfaceFD(Surf)%EnthNew, &
                                          SurfaceFD(Surf)%TDReport, &
                                          SurfaceFD(Surf)%CpOld, &
                                          SurfaceFD(Surf)%PhaseChangeDeltaT, &
                                          SurfaceFD(Surf)%Cp_node, &
                                          SurfaceFD(Surf)%PhaseChangeState, &
                                          SurfaceFD(Surf)%PhaseChangeStateold, &
                                          SurfaceFD(Surf)%PhaseChangeStateoldold, &
                                          SurfaceFD(Surf)%PhaseChangeTemperatureReverse,SurfaceFD(Surf)%PhaseChangeTransition )
!VE END

      TDT(I)  = SurfaceFD(Surf)%TDT(TotNodes + 1)
      TT(I)   = SurfaceFD(Surf)%TT(TotNodes + 1)
      RhoT(I) = SurfaceFD(Surf)%RhoT(TotNodes + 1)

    ELSE
!VE START@ SurfaceFD(Surf)%CpOld
      CALL InteriorBCEqns(Delt,nodeIn,LayIn,Surface(Surf)%ExtBoundCond,SurfaceFD(Surface(Surf)%ExtBoundCond)%T, &
SurfaceFD(Surface(Surf)%ExtBoundCond)%TT, & !potential-lkl-from old      CALL InteriorBCEqns(Delt,nodeIn,LayIn,Surf,SurfaceFD(Surface(Surf)%ExtBoundCond)%T, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%Rhov, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%RhoT, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%RH, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%TD, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%TDT, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%EnthOld, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%EnthNew, &
                                            SurfaceFD(Surface(Surf)%ExtBoundCond)%TDReport, &
					    SurfaceFD(Surf)%CpOld, &
                                            SurfaceFD(Surf)%PhaseChangeDeltaT, &
                                            SurfaceFD(Surf)%Cp_node, &
                                            SurfaceFD(Surf)%PhaseChangeState, &
                                            SurfaceFD(Surf)%PhaseChangeStateold, &
                                            SurfaceFD(Surf)%PhaseChangeStateoldold, &
                                            SurfaceFD(Surf)% PhaseChangeTemperatureReverse,SurfaceFD(Surf)%PhaseChangeTransition )
 
		! now fill results from interior BC model eqns into local result for current call
!VE END
      TDT(I)  = SurfaceFD(Surface(Surf)%ExtBoundCond)%TDT(TotNodes + 1)
      TT(I)   = SurfaceFD(Surface(Surf)%ExtBoundCond)%TT(TotNodes + 1)
      RhoT(I) = SurfaceFD(Surface(Surf)%ExtBoundCond)%RhoT(TotNodes + 1)

    ENDIF
!    CALL InteriorBCEqns(Delt,nodeIn,Layin,Surface(Surf)%ExtBoundCond,SurfaceFD(Surf)%T, &
!                                         SurfaceFD(Surf)%TT, &
!                                         SurfaceFD(Surf)%Rhov, &
!                                         SurfaceFD(Surf)%RhoT, &
!                                         SurfaceFD(Surf)%RH, &
!                                         SurfaceFD(Surf)%TD, &
!                                         SurfaceFD(Surf)%TDT, &
!                                         SurfaceFD(Surf)%EnthOld, &
!                                         SurfaceFD(Surf)%EnthNew)

    ! now fill results from interior BC model eqns into local result for current call
!    TDT(I)  = SurfaceFD(Surface(Surf)%ExtBoundCond)%TDT(TotNodes + 1)
!    TT(I)   = SurfaceFD(Surface(Surf)%ExtBoundCond)%TT(TotNodes + 1)
!    RhoT(I) = SurfaceFD(Surface(Surf)%ExtBoundCond)%RhoT(TotNodes + 1)
!    TDT(I)  = SurfaceFD(Surf)%TDT( i)
!    TT(I)   = SurfaceFD(Surf)%TT( i)
!    RhoT(I) = SurfaceFD(Surf)%RhoT( i)

    QNetSurfFromOutside = OpaqSurfInsFaceConductionFlux(Surface(Surf)%ExtBoundCond) !filled in InteriorBCEqns
!    QFluxOutsideToOutSurf(Surf)       = QnetSurfFromOutside
    OpaqSurfOutsideFaceConductionFlux(Surf)= -QnetSurfFromOutside
    OpaqSurfOutsideFaceConduction(Surf)     = Surface(Surf)%Area * OpaqSurfOutsideFaceConductionFlux(Surf)
    QHeatOutFlux(Surf)  = QnetSurfFromOutside

  ELSEIF (Surface(Surf)%ExtBoundCond <= 0) THEN   ! regular outside conditions

!++++++++++++++++++++++++++++++++++++++++++++++++++++++

    IF ( Surface(Surf)%HeatTransferAlgorithm == HeatTransferModel_CondFD  ) THEN

    ! regular outside conditions

     !  Set Thermal Conductivity.  Can be constant, simple linear temp dep or multiple linear segment temp function dep.


      kto = Material(MatLay)%Conductivity   !  20C base conductivity
      kt1 = MaterialFD(MatLay)%tk1  !  linear coefficient (normally zero)
      kt= kto + kt1*((TDT(I)+TDT(I+1))/2.d0 - 20.d0)

      IF( SUM(MaterialFD(MatLay)%TempCond(1:3,2)) >= 0.0d0) THEN ! Multiple Linear Segment Function

        DepVarCol= 2  ! thermal conductivity
        IndVarCol=1  !temperature
            !  Use average temp of surface and first node for k
        kt =terpld(MaterialFD(MatLay)%numTempCond,MaterialFD(MatLay)%TempCond,(TDT(I)+TDT(I+1))/2.d0,IndVarCol,DepVarCol)

      ENDIF


      RhoS = Material(MatLay)%Density
      Cpo = Material(MatLay)%SpecHeat
      Cp=Cpo  !  Will be changed if PCM
      Delx = ConstructFD(ConstrNum)%Delx(Lay)

          !Calculate the Dry Heat Conduction Equation

      MatLay = Construct(ConstrNum)%LayerPoint(Lay)
      IF (Material(MatLay)%ROnly .or. Material(MatLay)%Group == 1 ) THEN  ! R Layer or Air Layer  **********
               !  Use algebraic equation for TDT based on R

        Rlayer = Material(MatLay)%Resistance

        TDT(I)=(QRadSWOutFD*Rlayer + TDT(I+1) + hgnd*Rlayer*Tgnd + &
                   hconvo*Rlayer*Toa + hrad*Rlayer*Toa +  &
                   hsky*Rlayer*Tsky)/  &
                   (1 + hconvo*Rlayer + hgnd*Rlayer + hrad*Rlayer + &
                    hsky*Rlayer)
        IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
            (TDT(I) < MinSurfaceTempLimit) ) THEN
          TDT(I) = MAX(MinSurfaceTempLimit,MIN(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!          CALL CheckFDSurfaceTempLimits(I,TDT(I))
        ENDIF

      ELSE  ! Regular or phase change material layer

             !  check for phase change material
        IF( SUM(MaterialFD(MatLay)%TempEnth(1:3,2)) >= 0.0d0) THEN    !  phase change material,  Use TempEnth Data to generate Cp
!               CheckhT = Material(MatLay)%TempEnth       ! debug

          !       Enthalpy function used to get average specific heat.  Updated by GS so enthalpy function is followed.

          DepVarCol= 2  ! enthalpy
          IndVarCol=1  !temperature
          EnthOld(I) =terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TD(I),IndVarCol,DepVarCol)
          EnthNew(I) =terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TDT(I),IndVarCol,DepVarCol)
          IF (EnthNew(I)==EnthOld(I))  THEN
            Cp=Cpo
          ELSE
            Cp=MAX(Cpo,(EnthNew(I) -EnthOld(I))/(TDT(I)-TD(I)))
          END IF
         ELSE
           Cp = Cpo
         END IF ! Phase Change Material option
!VE START                         
             IF(Material(Matlay)%DeltaHS >0) THEN                                                           
              
                TempTlowPCM            =    Material(MatLay)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM        =    Material(MatLay)%TempHighPCM     ! Temperature at which Phase Change process ends           
                TempTlowPCF            =    Material(MatLay)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF        =    Material(MatLay)%TempHighPCF     ! Temperature at which Phase Change process ends 
    
                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                 
            
                    ELSE IF(TDT(I)>=TempTlowPCM .AND. TDT(I)<=TempThighPCM )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF
                        
                         IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                             (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                            PhaseChangeState(I) = 0
                         END IF
                    ELSE IF(TDT(I)>TempTHighPCM) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                        
                    END IF    

                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF) THEN
                       PhaseChangeState(I)=2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                                
                    ELSE IF (TDT(I)>=TempTlowPCF .AND. TDT(I)<=TempThighPCF) THEN
                       PhaseChangeState(I)=1
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1)) THEN 
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF (TDT(I)>TempThighPCF) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                    END IF
                 END IF
                    
                 IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==2)THEN    
                     PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                     PhaseChangeTransition(I) =1
                    PhaseChangeState(I)=0
                 ELSE IF(PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I)==0 )THEN    
                     PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==2 .AND.PhaseChangeState(I)==0)THEN   
                     PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                     PhaseChangeTransition(I) =1
                 ELSE 
                     PhaseChangeTransition(I) = 0
                 END IF
                
				IF (HysteresisFlag == 1) THEN   
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                        
                        
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                         IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                        
                             
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN   
                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM
                               Tau1 = Tau1M
                               Tau2 = Tau2M
                               DeltaH = DeltaHM
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF
                               Tau1 = Tau1F
                               Tau2 = Tau2F
                               DeltaH = DeltaHF
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1) THEN                        
                            
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)

                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                        
                            
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                        
                            
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                        
                        END IF 
                    END IF  
                END IF

                IF(PhaseChangeTransition(I)==0) THEN
                    
                    IF (EnthNew(I)==EnthOld(I))  THEN
                        Cp=CpOld(I)
                    ELSE
                        Cp = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM, EnthOld(I), EnthNew(I))            
                    END IF
                    
                ELSE IF(PhaseChangeTransition(I)==1) THEN
                    Cp =  SpecHeatTransition
                END IF
                
                Cp_node(I) = Cp

            ELSE    ! Regular Material
                Cp = Cpo
                Cp_node(I) = Cp
            END IF 
!VE END
!     Choose Regular or Transparent Insulation Case

        IF(HMovInsul <= 0.0d0 ) THEN  !  regular  case

          SELECT CASE (CondFDSchemeType)
          CASE (CrankNicholsonSecondOrder)
             !  Second Order equation
            TDT(I)= (1.0d0*QRadSWOutFD + (0.5d0*Cp*Delx*RhoS*TD(I))/DelT + (0.5d0*kt*(-1.0d0*TD(I) + TD(I+1)))/Delx  &
                     + (0.5d0*kt*TDT(I+1))/Delx + 0.5d0*hgnd*Tgnd + 0.5d0*hgnd*(-1.0d0*TD(I) + Tgnd) + 0.5d0*hconvo*Toa +   &
                        0.5d0*hrad*Toa  &
                     + 0.5d0*hconvo*(-1.d0*TD(I) + Toa) + 0.5d0*hrad*(-1.d0*TD(I) + Toa) + 0.5d0*hsky*Tsky +   &
                        0.5d0*hsky*(-1.d0*TD(I) + Tsky))/  &
                       (0.5d0*hconvo + 0.5d0*hgnd + 0.5d0*hrad + 0.5d0*hsky + (0.5d0*kt)/Delx + (0.5d0*Cp*Delx*RhoS)/DelT)
!feb2012            TDT(I)= (1.0d0*QRadSWOutFD + (0.5d0*Cp*Delx*RhoS*TD(I))/DelT + (0.5d0*kt*(-1.0d0*TD(I) + TD(I+1)))/Delx  &
!feb2012                     + (0.5d0*kt*TDT(I+1))/Delx + 0.5d0*hgnd*Tgnd + 0.5d0*hgnd*(-1.0d0*TD(I) + Tgnd) + 0.5d0*hconvo*Toa +   &
!feb2012                        0.5d0*hrad*Toa  &
!feb2012                     + 0.5d0*hconvo*(-1.d0*TD(I) + Toa) + 0.5d0*hrad*(-1.d0*TD(I) + Toa) + 0.5d0*hsky*Tsky +   &
!feb2012                        0.5d0*hsky*(-1.d0*TD(I) + Tsky))/  &
!feb2012                       (0.5d0*hconvo + 0.5d0*hgnd + 0.5d0*hrad + 0.5d0*hsky + (0.5d0*kt)/Delx + (0.5d0*Cp*Delx*RhoS)/DelT)

          CASE (FullyImplicitFirstOrder)
           !   First Order
            TDT(I)=(2.0d0*Delt*Delx*QRadSWOutFD + Cp*Delx**2*RhoS*TD(I) &
                    + 2.0d0*Delt*kt*TDT(I+1) + 2.0d0*Delt*Delx*hgnd*Tgnd  &
                    + 2.0d0*Delt*Delx*hconvo*Toa + 2.0d0*Delt*Delx*hrad*Toa + 2.0d0*Delt*Delx*hsky*Tsky)/  &
                     (2.0d0*Delt*Delx*hconvo + 2.0d0*Delt*Delx*hgnd + 2.0d0*Delt*Delx*hrad +  &
                       2.0d0*Delt*Delx*hsky + 2.0d0*Delt*kt + Cp*Delx**2*RhoS)

          END SELECT


        ELSE IF ( HMovInsul > 0.0d0) Then      !  Transparent insulation on outside
      !  Transparent insulaton additions

        !Movable Insulation Layer Outside surface temp

          TInsulOut = (QRadSWOutMvInsulFD + hgnd*Tgnd + HmovInsul*TDT(I) + &
                   hconvo*Toa + hrad*Toa + hsky*Tsky)/  &
                 (hconvo + hgnd + HmovInsul + hrad + hsky)

          !List(List(Rule(TDT,(2*Delt*Delx*QradSWOutAbs +
          !-       Cp*Delx**2*Rhos*TD + 2*Delt*kt*TDTP1 +
          !-       2*Delt*Delx*HmovInsul*Tiso)/
          !-     (2*Delt*Delx*HmovInsul + 2*Delt*kt + Cp*Delx**2*Rhos))))


         ! Wall first node temperature behind Movable insulation
          SELECT CASE (CondFDSchemeType)
          CASE (CrankNicholsonSecondOrder)
            TDT(I)= (2*Delt*Delx*QradSWOutFD +  &
                     Cp*Delx**2*Rhos*TD(I) + 2*Delt*kt*TDT(I+1) +  &
                      2*Delt*Delx*HmovInsul*TInsulOut)/  &
                       (2*Delt*Delx*HmovInsul + 2*Delt*kt + Cp*Delx**2*Rhos)

          CASE (FullyImplicitFirstOrder)
            ! Currently same as Crank Nicholson, need fully implicit formulation
            TDT(I)= (2*Delt*Delx*QradSWOutFD +  &
                     Cp*Delx**2*Rhos*TD(I) + 2*Delt*kt*TDT(I+1) +  &
                      2*Delt*Delx*HmovInsul*TInsulOut)/  &
                       (2*Delt*Delx*HmovInsul + 2*Delt*kt + Cp*Delx**2*Rhos)

          END SELECT

        End IF   !  Regular layer or Movable insulation cases

        IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
            (TDT(I) < MinSurfaceTempLimit) ) THEN
          TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!          CALL CheckFDSurfaceTempLimits(I,TDT(I))
        ENDIF


      END IF  ! R layer or Regular layer


    END IF   !End IF--ELSE SECTION (regular detailed FD part or SigmaR SigmaC part

    !  Determine net heat flux to ooutside face.
    !One formulation that works for Fully Implicit and CrankNicholson and massless wall

    QNetSurfFromOutside = QRadSWOutFD + (hgnd*(-TDT(I) + Tgnd) +  &
             hconvo*(-TDT(I) + Toa) + hrad*(-TDT(I) + Toa) + hsky*(-TDT(I) + Tsky))

    !Same sign convention as CTFs
    OpaqSurfOutsideFaceConductionFlux(Surf) = -QnetSurfFromOutside
    OpaqSurfOutsideFaceConduction(Surf)     = Surface(Surf)%Area * OpaqSurfOutsideFaceConductionFlux(Surf)

    !Report all outside BC heat fluxes
    QdotRadOutRepPerArea(Surf) = -(hgnd*(TDT(I) - Tgnd) +  hrad*(TDT(I) - Toa) + hsky*( TDT(I) - Tsky))
    QdotRadOutRep(Surf)        = Surface(Surf)%Area * QdotRadOutRepPerArea(Surf)
    QRadOutReport(Surf)     = QdotRadOutRep(Surf) * SecInHour * TimeStepZone

  END IF  !End IF --ELSE SECTION (regular BC part of the ground and Rain check)


RETURN

END SUBROUTINE ExteriorBCEqns
!VE START@ CpOld
SUBROUTINE InteriorNodeEqns(Delt,I,Lay,Surf,T,TT,Rhov,RhoT,RH,TD,TDT,EnthOld,EnthNew,CpOld, &
                            PhaseChangeDeltaT,PhaseChangeTransition, Cp_node,PhaseChangeState,PhaseChangeStateold, PhaseChangeTransitionOld, &
                            PhaseChangeDeltaTOld,PhaseChangeStateoldold,Tr) 
!VE END


          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard Liesen
          !       DATE WRITTEN   November, 2003
          !       MODIFIED       May 2011, B. Griffith and P. Tabares
          !       RE-ENGINEERED  C. O. Pedersen, 2006

          ! PURPOSE OF THIS SUBROUTINE:
          ! <description>

          ! METHODOLOGY EMPLOYED:
          ! <description>

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
          ! na

  IMPLICIT NONE ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
  INTEGER, INTENT(IN)  :: Delt  ! Time Increment
  INTEGER, INTENT(IN)  :: I     ! Node Index
  INTEGER, INTENT(IN)  :: Lay   ! Layer Number for Construction
  INTEGER, INTENT(IN)  :: Surf  ! Surface number
  REAL(r64),DIMENSION(:), INTENT(In)    :: T     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TT    !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(In)    :: Rhov     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RhoT  !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(In)    :: TD     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TDT    !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RH    !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthOld    ! Old Nodal enthalpy
  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthNew    ! New Nodal enthalpy
!VE START 
    REAL(r64),Dimension(100) :: EnthalpyF  
    REAL(r64),Dimension(100) :: EnthalpyM 
    REAL(r64),Dimension(100) :: Enthalpy
    REAL(r64),Dimension(:), Intent(InOut) :: CpOld   
    REAL(r64),Dimension(:), Intent(InOut) :: Cp_node      ! Nodal Specific Heat
    REAL(r64),Dimension(:), Intent(In) :: PhaseChangeDeltaT
    REAL(r64),Dimension(:), Intent(In) :: PhaseChangeDeltaTOld
    INTEGER,Dimension(:), Intent(InOut) :: PhaseChangeTransition
    INTEGER,Dimension(:), Intent(In) :: PhaseChangeTransitionOld
    REAL(r64)  :: Tc
    REAL(r64)    :: DeltaH
    Integer,Dimension(:),Intent(InOut)        ::PhaseChangeState 
    Integer,Dimension(:),Intent(In)            ::PhaseChangeStateold
    Integer,Dimension(:),Intent(In)            ::PhaseChangeStateoldold 
    REAL(r64),Dimension(:), Intent(In)        :: Tr ! PhaseChangeTemperatureReverse 
    REAL(r64), Dimension(100)  :: EnthRev
    REAL(r64), PARAMETER :: NinetyNine=99.0d0
!VE END

         ! SUBROUTINE PARAMETER DEFINITIONS:
!  REAL(r64), PARAMETER :: NinetyNine=99.0d0

          ! INTERFACE BLOCK SPECIFICATIONS:
          ! na

          ! DERIVED TYPE DEFINITIONS:
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
          ! na

  REAL(r64) :: Delx

  INTEGER :: ConstrNum
  INTEGER :: MatLay
  INTEGER :: DepVarCol
  INTEGER :: IndVarCol

  REAL(r64) :: kt  !  Thermal conductivity in temperature equation
  REAL(r64) :: ktA1  !  Variable Outer Thermal conductivity in temperature equation
  REAL(r64) :: ktA2  !  Thermal Inner conductivity in temperature equation
  REAL(r64) :: kto !  base 20 C thermal conductivity
  REAL(r64) :: kt1 !  temperature coefficient for simple temp dep k.
  REAL(r64) :: Cp   !  Cp used
  REAL(r64) :: Cpo  !  Const Cp from input
  REAL(r64) :: RhoS
!VE START
    REAL(r64)         :: TempTlowPCM
    REAL(r64)         :: TempThighPCM
    REAL(r64)         :: TempTlowPCF
    REAL(r64)         :: TempThighPCF
    REAL(r64)         :: SpecHeatSolidPCM
    REAL(r64)         :: SpecHeatLiquidPCM
    REAL(r64)         :: SpecHeatTransition
    INTEGER           :: TransFlag
    
    !*****************************************************************************
    ! These are variables that explicitly hold the freezing and melting curve 
    ! properties and are used  in the transition region only
    REAL(r64)         :: Tau1M ! Melting Region low
    REAL(r64)         :: Tau2M ! Melting Region high
    REAL(r64)         :: Tau1F ! Freezing Region low
    REAL(r64)         :: Tau2F ! Freezing Region high
    REAL(r64)         :: DeltaHM ! Latent heat of Melting
    REAL(r64)         :: DeltaHF ! Latent heat of Freezing
    !********************************************************************************
  !VE END 

  ConstrNum=Surface(surf)%Construction

  MatLay = Construct(ConstrNum)%LayerPoint(Lay)

!VE START  
    TcM = Material(MatLay)%Tm
    Tau1 = Material(MatLay)%Tau1
    Tau2 = Material(MatLay)%Tau2
    TempTlowPCM       = TcM-Tau1        ! Temperature at which Phase Change process starts
    TempThighPCM      = TcM+Tau2    ! Temperature at which Phase Change process ends 
    Material(MatLay)%TempLowPCM = TempTlowPCM            
    Material(MatLay)%TempHighPCM= TempThighPCM      
    TcF = Material(MatLay)%Tf
    Tau1F = Material(MatLay)%Tau1Prime
    Tau2F = Material(MatLay)%Tau2Prime
    TempTlowPCF       = TcF-Tau1F        ! Temperature at which Phase Change process starts
    TempThighPCF      = TcF+Tau2F    ! Temperature at which Phase Change process ends         
    Material(MatLay)%TempLowPCF = TempTlowPCF            
    Material(MatLay)%TempHighPCF= TempThighPCF  
    SpecHeatSolidPCM  = Material(MatLay)%CpSolid
    SpecHeatLiquidPCM = Material(MatLay)%CpLiquid
    SpecHeatTransition = (SpecHeatSolidPCM+SpecHeatLiquidPCM)/2
    DeltaHM = Material(MatLay)%DeltaHF
    DeltaHF = Material(MatLay)%DeltaHS
    Tau1M = Material(MatLay)%Tau1
    Tau2M = Material(MatLay)%Tau2
    Tau1F = Material(MatLay)%Tau1Prime
    Tau2F = Material(MatLay)%Tau2Prime 
!VE END
   !  Set Thermal Conductivity.  Can be constant, simple linear temp dep or multiple linear segment temp function dep.
  kto = Material(MatLay)%Conductivity   !  20C base conductivity
  kt1 = MaterialFD(MatLay)%tk1  !  linear coefficient (normally zero)
  kt  = kto + kt1*((TDT(I)+TDT(I-1))/2.d0 - 20.0d0)
  ktA1 = kto + kt1*((TDT(I)+TDT(I+1))/2.d0 - 20.0d0)   ! Will be overridden if variable k
  ktA2 = kto + kt1*((TDT(I)+TDT(I-1))/2.d0 - 20.0d0)   ! Will be overridden if variable k

  IF( SUM(MaterialFD(MatLay)%TempCond(1:3,2)) >= 0.0d0) THEN ! Multiple Linear Segment Function

    DepVarCol = 2  ! thermal conductivity
    IndVarCol = 1  !temperature
    ktA1 = terpld(MaterialFD(MatLay)%numTempCond,MaterialFD(MatLay)%TempCond,(TDT(I)+TDT(I+1))/2.0d0 ,IndVarCol,DepVarCol)
    ktA2 = terpld(MaterialFD(MatLay)%numTempCond,MaterialFD(MatLay)%TempCond,(TDT(I)+TDT(I-1))/2.0d0 ,IndVarCol,DepVarCol)
  ENDIF

  RhoS = Material(MatLay)%Density
  Cpo  = Material(MatLay)%SpecHeat
  Cp   = Cpo  ! Will be changed if PCM
  Delx = ConstructFD(ConstrNum)%Delx(Lay)

  IF( SUM(MaterialFD(MatLay)%TempEnth(1:3,2)) >= 0.0d0) THEN    !  phase change material,  Use TempEnth Data

    DepVarCol = 2  ! enthalpy
    IndVarCol = 1  !temperature
    EnthOld(I) =terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TD(I),IndVarCol,DepVarCol)
    EnthNew(I) =terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TDT(I),IndVarCol,DepVarCol)
    IF (EnthNew(I)==EnthOld(I))  THEN
      Cp = Cpo
    ELSE
      Cp = MAX(Cpo,(EnthNew(I) -EnthOld(I))/(TDT(I)-TD(I)))
    END IF

  ELSE  ! No phase change

    Cp = Cpo

  END IF ! Phase Change case
!VE START
             IF(Material(Matlay)%DeltaHS >0) THEN                                                           
                TempTlowPCM            =    Material(MatLay)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM        =    Material(MatLay)%TempHighPCM     ! Temperature at which Phase Change process ends           
                TempTlowPCF            =    Material(MatLay)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF        =    Material(MatLay)%TempHighPCF     ! Temperature at which Phase Change process ends   
                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                            
                    ELSE IF(TDT(I)>=TempTlowPCM .AND. TDT(I)<=TempThighPCM )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                        
                         IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                             (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                            PhaseChangeState(I) = 0
                         END IF
                    ELSE IF(TDT(I)>TempTHighPCM) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                        
                    END IF    
                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF) THEN
                       PhaseChangeState(I)=2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS                               
                    ELSE IF (TDT(I)>=TempTlowPCF .AND. TDT(I)<=TempThighPCF) THEN
                       PhaseChangeState(I)=1
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1)) THEN 
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF (TDT(I)>TempThighPCF) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                    END IF
                 END IF                
                 IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1)THEN    
                    PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                    PhaseChangeTransition(I) =1
                    PhaseChangeState(I)=0
                 ELSE IF(PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I)==0 )THEN    
                     PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I)==0)THEN   
                     PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                     PhaseChangeTransition(I) =1
                 ELSE 
                     PhaseChangeTransition(I) = 0
                 END IF                  
				IF (HysteresisFlag == 1) THEN  !VE-2016--CC is this stuff needed? JDC I really do not think so. 
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                         
                        IF (TDT(I) > Tr(I) .AND. EnthNew(I) < EnthalpyF(I)) THEN
                            Tc= TcOld
                            EnthNew(I) = SpecEnthalpy(I,TDT(I), TcOld, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                        END IF
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                          IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                                                    
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN                              
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM
                               Tau1 = Tau1M
                               Tau2 = Tau2M
                               DeltaH = DeltaHM
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF
                               Tau1 = Tau1F
                               Tau2 = Tau2F
                               DeltaH = DeltaHF
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)                          
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1) THEN                                                   
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                                                  
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)                          
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                                                    
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))                       
                        END IF 
                    END IF  
                END IF
                IF(PhaseChangeTransition(I)==0) THEN                    
                    IF (EnthNew(I)==EnthOld(I))  THEN
                        Cp=CpOld(I)
                    ELSE
                        Cp = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM, EnthOld(I), EnthNew(I))            
                    END IF                  
                ELSE IF(PhaseChangeTransition(I)==1) THEN
                    Cp =  SpecHeatTransition
                END IF               
                Cp_node(I) = Cp
            ELSE    ! Regular Material
                Cp = Cpo
                Cp_node(I) = Cp
            END IF 
!VE END

  SELECT CASE (CondFDSchemeType)

  CASE (CrankNicholsonSecondOrder)
    ! Adams-Moulton second order
    TDT(I)= ((Cp*Delx*RhoS*TD(I))/Delt +   &
              0.5d0*((ktA2*(-1.0d0*TD(I) + TD(I-1)))/Delx + (ktA1*(-1.d0*TD(I) + TD(I+1)))/Delx) +   &
              (0.5d0*ktA2*TDT(I-1))/Delx + (0.5d0*ktA1*TDT(I+1))/Delx)/  &
              ((0.5d0*(ktA1+ktA2))/Delx + (Cp*Delx*RhoS)/Delt)


  CASE (FullyImplicitFirstOrder)
    ! Adams-Moulton First order
        TDT(I)= ((Cp*Delx*RhoS*TD(I))/Delt +   &
                 (1.d0*ktA2*TDT(I-1))/Delx + (1.d0*ktA1*TDT(I+1))/Delx)/  &
                 ((2.d0*(ktA1+ktA2)/2.d0)/Delx + (Cp*Delx*RhoS)/Delt)


  END SELECT

 IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
     (TDT(I) < MinSurfaceTempLimit) ) THEN
   TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!   CALL CheckFDSurfaceTempLimits(I,TDT(I))
  ENDIF

RETURN

END SUBROUTINE InteriorNodeEqns

!VE START@ CpOld1
SUBROUTINE IntInterfaceNodeEqns(Delt,I,Lay,Surf,T,TT,Rhov,RhoT,RH,TD,TDT,EnthOld,EnthNew,GSiter,CpOld1,CpOld2,PhaseChangeDeltaT, PhaseChangeTransition, &
                                Cp1_node,Cp2_node,PhaseChangeState,PhaseChangeStateold,PhaseChangeStateoldold, &
                                Tr)
!VE END
          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard Liesen
          !       DATE WRITTEN   November, 2003
          !       MODIFIED       May 2011, B. Griffith, P. Tabares,  add first order fully implicit, bug fixes, cleanup
		  !                      2013-2016, NRGsim Inc., added  Material Property Phase Change Hysteresis Routines.		  
          !       RE-ENGINEERED  Curtis Pedersen, Changed to Implit mode and included enthalpy.  FY2006

          ! PURPOSE OF THIS SUBROUTINE:
          ! calculate finite difference heat transfer for nodes that interface two different material layers inside construction

          ! METHODOLOGY EMPLOYED:
          ! na

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
          ! na

  IMPLICIT NONE ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:

  INTEGER, INTENT(IN)  :: Delt  ! Time Increment
  INTEGER, INTENT(IN)  :: I     ! Node Index
  INTEGER, INTENT(IN)  :: Lay   ! Layer Number for Construction
  INTEGER, INTENT(IN)  :: Surf  ! Surface number
  INTEGER, INTENT(IN)  :: GSiter  ! Iteration number of Gauss Seidell iteration
  REAL(r64),DIMENSION(:), INTENT(In)    :: T     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TT    !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(In)    :: Rhov     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RhoT  !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(In)    :: TD     !OLD NODE TEMPERATURES OF EACH HEAT TRANSFER SURF IN CONDFD.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TDT    !NEW NODE TEMPERATURES OF EACH HEAT TRANSFER SURF IN CONDFD.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RH    !RELATIVE HUMIDITY.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthNew    ! New Nodal enthalpy
!VE START 
!REAL(r64),DIMENSION(:), INTENT(In)    :: EnthOld    ! Old Nodal enthalpy V8 !JDC BugCheck Single Curve is "In", dual curve "InOut"

  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthOld    ! Old Nodal enthalpy VE !JDC BugCheck Single Curve is "In", dual curve "InOut"
  REAL(r64),Dimension(100)              :: EnthalpyF  
  REAL(r64),Dimension(100)              :: EnthalpyM 
  REAL(r64),Dimension(100)              :: EnthRev 
  INTEGER, Dimension(:), Intent(InOut)   :: PhaseChangeTransition
  REAL(r64),Dimension(:), Intent(In)    :: Tr !  PhaseChangeTemperatureReverse
    REAL(r64),Dimension(:), Intent(InOut)    :: CpOld1
    REAL(r64),Dimension(:), Intent(InOut)    :: CpOld2
    REAL(r64),Dimension(:), Intent(InOut)    :: Cp1_node      ! Nodal Specific Heat 1
    REAL(r64),Dimension(:), Intent(InOut)    :: Cp2_node      ! Nodal Specific Heat 2
    REAL(r64),Dimension(:), Intent(InOut)    :: PhaseChangeDeltaT 
    Integer,Dimension(:),Intent(InOut)        ::PhaseChangeState
    Integer,Dimension(:), Intent(InOut)       ::PhaseChangeStateold
    Integer,Dimension(:),Intent(InOut)        ::PhaseChangeStateoldold
    REAL(r64)    :: Tc
    REAL(r64)    :: Tc2
    REAL(r64)    :: DeltaH
    REAL(r64)    :: DeltaH2
!VE END
          ! SUBROUTINE PARAMETER DEFINITIONS:
!  REAL(r64), PARAMETER :: NinetyNine=99.0d0

          ! INTERFACE BLOCK SPECIFICATIONS:
          ! na

          ! DERIVED TYPE DEFINITIONS:
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:

  INTEGER :: ConstrNum
  INTEGER :: MatLay
  INTEGER :: MatLay2
  INTEGER :: IndVarCol
  INTEGER :: DepVarCol

  REAL(r64) :: kt1
  REAL(r64) :: kt2
  REAL(r64) :: kt1o
  REAL(r64) :: kt2o
  REAL(r64) :: kt11
  REAL(r64) :: kt21
  REAL(r64) :: Cp1
  REAL(r64) :: Cp2
  REAL(r64) :: Cpo1
  REAL(r64) :: Cpo2
  REAL(r64) :: RhoS1
  REAL(r64) :: RhoS2

  REAL(r64) :: Delx1
  REAL(r64) :: Delx2
  REAL(r64) :: Enth1New
  REAL(r64) :: Enth2New
  REAL(r64) :: Enth1Old
  REAL(r64) :: Enth2Old

  REAL(r64) :: Rlayer   !  resistance value of R Layer
  REAL(r64) :: Rlayer2  !  resistance value of next layer to inside
  REAL(r64) :: QSSFlux  !  Source/Sink flux value at a layer interface
  LOGICAL   :: RlayerPresent  = .FALSE.
  LOGICAL   :: RLayer2Present = .FALSE.


!VE START
    REAL(r64), PARAMETER :: NinetyNine=99.0d0
    REAL(r64)         :: TempTlowPCM
    REAL(r64)         :: TempThighPCM
    REAL(r64)         :: TempTlowPCF
    REAL(r64)         :: TempThighPCF
    REAL(r64)         :: SpecHeatSolidPCM
    REAL(r64)         :: SpecHeatLiquidPCM

    !*****************************************************************************
    ! These are variables that explicitly hold the freezing and melting curve 
    ! Properties and are used  in the transition region only for PCM Layer #1
    REAL(r64)         :: Tau1M ! Melting range
    REAL(r64)         :: Tau2M ! Melting range
    REAL(r64)         :: Tau1F ! Freezing Range 
    REAL(r64)         :: Tau2F ! Freezing Region
    REAL(r64)         :: DeltaHM ! Latent heat of Melting
    REAL(r64)         :: DeltaHF ! Latent heat of Freezing
    !********************************************************************************

    REAL(r64)         :: TempTlowPCM2
    REAL(r64)         :: TempThighPCM2
    REAL(r64)         :: TempTlowPCF2
    REAL(r64)         :: TempThighPCF2
    REAL(r64)         :: SpecHeatSolidPCM2 
    REAL(r64)         :: SpecHeatLiquidPCM2
    REAL(r64)         :: SpecHeatTransition
    REAL(r64)         :: SpecHeatTransition2
 
    REAL(r64)         :: Tau12
    REAL(r64)         :: Tau22
    REAL(r64)         :: TcM2
    REAL(r64)         :: Tau1F2
    REAL(r64)         :: Tau2F2
    REAL(r64)         :: TcF2

    !*****************************************************************************
    ! These are variables that explicitly hold the freezing and melting curve 
    ! properties and are used  in the transition region only for PCM Layer #2
    REAL(r64)         :: Tau12M ! Melting range
    REAL(r64)         :: Tau22M ! Melting range
    REAL(r64)         :: Tau12F ! Freezing Range 
    REAL(r64)         :: Tau22F ! Freezing Region
    REAL(r64)         :: DeltaH2M ! Latent heat of Melting
    REAL(r64)         :: DeltaH2F ! Latent heat of Freezing
    !********************************************************************************
 !VE END
  ConstrNum=Surface(surf)%Construction

  MatLay = Construct(ConstrNum)%LayerPoint(Lay)
  MatLay2 = Construct(ConstrNum)%LayerPoint(Lay+1) 
 !VE START   

    TcM = Material(MatLay)%Tm
    Tau1 = Material(MatLay)%Tau1
    Tau2 = Material(MatLay)%Tau2
    TempTlowPCM       = TcM-Tau1        ! Temperature at which Phase Change process starts
    TempThighPCM      = TcM+Tau2    ! Temperature at which Phase Change process ends 
    Material(MatLay)%TempLowPCM = TempTlowPCM            
    Material(MatLay)%TempHighPCM= TempThighPCM

    TcF = Material(MatLay)%Tf
    Tau1F = Material(MatLay)%Tau1Prime
    Tau2F = Material(MatLay)%Tau2Prime
    TempTlowPCF       = TcF-Tau1F        ! Temperature at which Phase Change process starts
    TempThighPCF      = TcF+Tau2F    ! Temperature at which Phase Change process ends         
    Material(MatLay)%TempLowPCF = TempTlowPCF            
    Material(MatLay)%TempHighPCF= TempThighPCF

    TcM2 = Material(MatLay2)%Tm
    Tau12 = Material(MatLay2)%Tau1
    Tau22 = Material(MatLay2)%Tau2
    TempTlowPCM2       = TcM2-Tau12        ! Temperature at which Phase Change process starts
    TempThighPCM2      = TcM2+Tau22    ! Temperature at which Phase Change process ends 
    Material(MatLay2)%TempLowPCM = TempTlowPCM2            
    Material(MatLay2)%TempHighPCM= TempThighPCM2

    TcF2 = Material(MatLay2)%Tf
    Tau1F2 = Material(MatLay2)%Tau1Prime
    Tau2F2 = Material(MatLay2)%Tau2Prime
    TempTlowPCF2       = TcF2-Tau1F2        ! Temperature at which Phase Change process starts
    TempThighPCF2      = TcF2+Tau2F2    ! Temperature at which Phase Change process ends         
    Material(MatLay2)%TempLowPCF = TempTlowPCF2            
    Material(MatLay2)%TempHighPCF= TempThighPCF2
    
    SpecHeatSolidPCM  = Material(MatLay)%CpSolid
    SpecHeatLiquidPCM = Material(MatLay)%CpLiquid
    SpecHeatSolidPCM2  = Material(MatLay2)%CpSolid
    SpecHeatLiquidPCM2 = Material(MatLay2)%CpLiquid
    SpecHeatTransition = (SpecHeatSolidPCM + SpecHeatLiquidPCM)/2
    SpecHeatTransition2 = (SpecHeatSolidPCM2 + SpecHeatLiquidPCM2)/2
    
    DeltaHM = Material(MatLay)%DeltaHF
    DeltaHF = Material(MatLay)%DeltaHS
    Tau1M = Material(MatLay)%Tau1
    Tau2M = Material(MatLay)%Tau2
    Tau1F = Material(MatLay)%Tau1Prime
    Tau2F = Material(MatLay)%Tau2Prime 
    
    DeltaH2M = Material(MatLay2)%DeltaHF
    DeltaH2F = Material(MatLay2)%DeltaHS
    Tau12M = Material(MatLay2)%Tau1
    Tau22M = Material(MatLay2)%Tau2
    Tau12F = Material(MatLay2)%Tau1Prime
    Tau22F = Material(MatLay2)%Tau2Prime 
!VE END

  !  Set Thermal Conductivity.  Can be constant, simple linear temp dep or multiple linear segment temp function dep.

  kt1o = Material(MatLay)%Conductivity
  kt11=  MaterialFD(MatLay)%tk1
  kt1= kt1o + kt11*((TDT(I)+TDT(I-1))/2.d0 -20.d0)

  IF( SUM(MaterialFD(MatLay)%TempCond(1:3,2)) >= 0.0d0) THEN ! Multiple Linear Segment Function

    IndVarCol = 1  ! temperature
    DepVarCol = 2  ! thermal conductivity
    kt1       = terpld(MaterialFD(MatLay)%numTempCond,MaterialFD(MatLay)%TempCond,(TDT(I)+TDT(I-1))/2.d0,IndVarCol,DepVarCol)

  ENDIF

  RhoS1 = Material(MatLay)%Density
  Cpo1 = Material(MatLay)%SpecHeat   ! constant Cp from input file
  Delx1 = ConstructFD(ConstrNum)%Delx(Lay)
  Rlayer = Material(MatLay)%Resistance

  kt2o = Material(MatLay2)%Conductivity
  kt21=  MaterialFD(MatLay2)%tk1
  kt2= kt2o + kt21*((TDT(I)+TDT(I+1))/2.d0 -20.d0)

  IF( SUM(MaterialFD(MatLay2)%TempCond(1:3,2)) >= 0.0d0) THEN ! Multiple Linear Segment Function

    IndVarCol = 1  ! temperature
    DepVarCol = 2  ! thermal conductivity
    kt2 =terpld(MaterialFD(MatLay2)%numTempCond,MaterialFD(MatLay2)%TempCond,(TDT(I)+TDT(I+1))/2.d0,IndVarCol,DepVarCol)

  ENDIF

  RhoS2 = Material(MatLay2)%Density
  Cpo2 = Material(MatLay2)%SpecHeat
  Delx2 = ConstructFD(ConstrNum)%Delx(Lay+1)
  Rlayer2 = Material(MatLay2)%Resistance
  Cp1=Cpo1   !  Will be reset if PCM
  Cp2=Cpo2   !  will be reset if PCM

  IF ( Surface(Surf)%HeatTransferAlgorithm ==  HeatTransferModel_CondFD )THEN  !HT Algo issue
              !Calculate the Dry Heat Conduction Equation
    RLayerPresent = .FALSE.
    RLayer2Present = .false.

!     Source/Sink Flux Capability ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

    QSSFlux = 0.0d0
    IF (Surface(Surf)%Area >0.0d0 .and.   &
        Construct(ConstrNum)%SourceSinkPresent .and. Lay == Construct(ConstrNum)%SourceAfterLayer) then

      QSSFlux = QRadSysSource(Surf)/Surface(Surf)%Area   &
                 + QPVSysSource(Surf)/Surface(Surf)%Area     ! Includes QPV Source

    END IF

!++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

    IF (Material(MatLay)%ROnly .or. Material(MatLay)%Group == 1)  RLayerPresent = .TRUE.

    IF (Material(MatLay2)%ROnly .or. Material(MatLay2)%Group ==1) Rlayer2Present =.TRUE.

    IF ( RLayerPresent .and. RLayer2Present) THEN
      TDT(I)=(Rlayer2*TDT(I-1) + Rlayer*TDT(I+1))/(Rlayer + Rlayer2)   ! two adjacent R layers

    ELSE IF ( RLayerPresent .and. .not. RLayer2Present  ) THEN  ! R-layer first

     !  Check for PCM second layer
     IndVarCol = 1  ! temperature
     DepVarCol = 2  ! thermal conductivity

      IF( Sum(MaterialFD(MatLay)%TempEnth(1:3,2)) < 0.0d0  &
             .and. Sum(MaterialFD(MatLay2)%TempEnth(1:3,2)) > 0.0d0) THEN    !  phase change material Layer2,  Use TempEnth Data

        Enth2Old = terpld(MaterialFD(MatLay2)%numTempEnth,MaterialFD(MatLay2)%TempEnth,TD(I),IndVarCol,DepVarCol)
        Enth2New = terpld(MaterialFD(MatLay2)%numTempEnth,MaterialFD(MatLay2)%TempEnth,TDT(I),IndVarCol,DepVarCol)
        EnthNew(I) = Enth2New  !  This node really doesn't have an enthalpy, this gives it a value

        IF (ABS(Enth2New-Enth2Old) <= smalldiff .or. ABS(TDT(I)-TD(I)) <= smalldiff)  THEN
          Cp2 = Cpo2
        ELSE
          Cp2 = MAX(Cpo2,(Enth2New -Enth2Old)/(TDT(I)-TD(I)))
        END IF
      ENDIF
!VE START
            IF(Material(MatLay)%DeltaHS <=0 .AND. Material(MatLay2)%DeltaHS>0) THEN
                
                TempTlowPCM            =    Material(MatLay)%TempLowPCM        ! Temperature at which melting process starts
                TempThighPCM        =    Material(MatLay)%TempHighPCM     ! Temperature at which melting process ends
                TempTlowPCM2        =    Material(MatLay2)%TempLowPCM        ! Temperature at which melting process starts
                TempThighPCM2        =    Material(MatLay2)%TempHighPCM     ! Temperature at which melting process ends
                
                TempTlowPCF            =    Material(MatLay)%TempLowPCF        ! Temperature at which freezing process starts
                TempThighPCF        =    Material(MatLay)%TempHighPCF     ! Temperature at which freezing process ends
                TempTlowPCF2        =    Material(MatLay2)%TempLowPCF        ! Temperature at which freezing process starts
                TempThighPCF2        =    Material(MatLay2)%TempHighPCF     ! Temperature at which freezing process ends
                         
                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM2) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM2
                        Tau1 = Material(MatLay2)%Tau1
                        Tau2 = Material(MatLay2)%Tau2
                        DeltaH = Material(MatLay2)%DeltaHF                 
            
                    ELSE IF(TDT(I)>=TempTlowPCM2 .AND. TDT(I)<=TempThighPCM2 )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM2
                        Tau1 = Material(MatLay2)%Tau1
                        Tau2 = Material(MatLay2)%Tau2
                        DeltaH = Material(MatLay2)%DeltaHF
                        
                        IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                            (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF(TDT(I)>TempTHighPCM2) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcM2
                        Tau1 = Material(MatLay2)%Tau1
                        Tau2 = Material(MatLay2)%Tau2
                        DeltaH = Material(MatLay2)%DeltaHF                        
                    END IF    

                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF2) THEN
                       PhaseChangeState(I)=2
                        Tc = TcF2
                        Tau1 = Material(MatLay2)%Tau1Prime
                        Tau2 = Material(MatLay2)%Tau2Prime
                        DeltaH = Material(MatLay2)%DeltaHS
                                
                    ELSE IF (TDT(I)>=TempTlowPCF2 .AND. TDT(I)<=TempThighPCF2) THEN
                       PhaseChangeState(I)=1
                        Tc = TcF2
                        Tau1 = Material(MatLay2)%Tau1Prime
                        Tau2 = Material(MatLay2)%Tau2Prime
                        DeltaH = Material(MatLay2)%DeltaHS
                        
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1))THEN
                           PhaseChangeState(I) = 0
                        END IF

                    ELSE IF (TDT(I)>TempThighPCF2) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcF2
                        Tau1 = Material(MatLay2)%Tau1Prime
                        Tau2 = Material(MatLay2)%Tau2Prime
                        DeltaH = Material(MatLay2)%DeltaHS
                    END IF
                 END IF
                    
				IF (HysteresisFlag == 1) THEN 
                    IF(PhaseChangeTransition(I) == 0)THEN
                        Enth2Old = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)                    
                        Enth2New = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                        
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                          IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                        
                             
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN   
                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM2
                               Tau1 = Tau12M
                               Tau2 = Tau22M
                               DeltaH = DeltaH2M
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF2
                               Tau1 = Tau12F
                               Tau2 = Tau22F
                               DeltaH = DeltaH2F
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==2) THEN                        
                            
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)

                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                        
                            
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                        
                            
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                        
                        END IF 
                        Enth2New = EnthNew(I)
                    END IF  
                END IF  
             
                IF(PhaseChangeTransition(I)==0) THEN
                    
                    IF (Enth2New==Enth2Old)  THEN
                        Cp2=CpOld2(I)
                    ELSE
                        Cp2 = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM, EnthOld(I), EnthNew(I))            
                    END IF
                    
                ELSE IF(PhaseChangeTransition(I)==1) THEN
                    Cp2 = SpecHeatTransition2
                END IF


                EnthNew(I) = Enth2New  !  This node really doesn't have an enthalpy, this gives it a value
        
                Cp2_node(I)=Cp2

            ELSE    ! Regular Material
                Cp2 = Cpo2
                Cp2_node=Cp2
            END IF 
!VE END
         ! R layer first, then PCM or regular layer.
      SELECT CASE (CondFDSchemeType)
        CASE (CrankNicholsonSecondOrder)

          TDT(I) =( 2.d0*delt*Delx2*QSSFlux*Rlayer - delt*Delx2*TD(I) - delt*kt2*Rlayer*TD(I) +  &
                Cp2*Delx2**2*RhoS2*Rlayer*TD(I) + delt*Delx2*TD(I-1) + delt*kt2*Rlayer*TD(I+1) + delt*Delx2*TDT(I-1) +  &
                delt*kt2*Rlayer*TDT(I+1))/(delt*Delx2 + delt*kt2*Rlayer + Cp2*Delx2**2.d0*RhoS2*Rlayer)

        CASE (FullyImplicitFirstOrder)

          TDT(I) =( 2.d0*delt*Delx2*QSSFlux*Rlayer + Cp2*Delx2**2*RhoS2*Rlayer*TD(I) + 2.d0*delt*Delx2*TDT(I-1) +  &
                 2.d0*delt*kt2*Rlayer*TDT(I+1))/(2.d0*delt*Delx2 + 2.d0*delt*kt2*Rlayer + Cp2*Delx2**2.d0*RhoS2*Rlayer)

      END SELECT

      IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
          (TDT(I) < MinSurfaceTempLimit) ) THEN
        TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!        CALL CheckFDSurfaceTempLimits(I,TDT(I))
      ENDIF

    ELSE IF (.not. RLayerPresent .and.  RLayer2Present) THEN  ! R-layer second

      !  check for PCM layer before R layer
     IndVarCol = 1  ! temperature
     DepVarCol = 2  ! thermal conductivity

      IF( SUM(MaterialFD(MatLay)%TempEnth(1:3,2)) > 0.0d0  &
          .and. SUM(MaterialFD(MatLay2)%TempEnth(1:3,2)) < 0.0d0) THEN    !  phase change material Layer1,  Use TempEnth Data

        Enth1Old = terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TD(I),IndVarCol,DepVarCol)
        Enth1New = terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TDT(I),IndVarCol,DepVarCol)
        EnthNew(I) = Enth1New    !  This node really doesn't have an enthalpy, this gives it a value

        IF (ABS(Enth1New-Enth1Old) <= smalldiff .or. ABS(TDT(I)-TD(I)) <= smalldiff)  THEN
          Cp1=Cpo1
        ELSE
          Cp1=Max(Cpo1,(Enth1New -Enth1Old)/(TDT(I)-TD(I)))
        END IF

      ENDIF
!VE START
            IF( Material(MatLay)%DeltaHS >0 .AND. Material(MatLay2)%DeltaHS<=0) THEN         
                TempTlowPCM            =    Material(MatLay)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM        =    Material(MatLay)%TempHighPCM     ! Temperature at which Phase Change process ends           
                TempTlowPCF            =    Material(MatLay)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF        =    Material(MatLay)%TempHighPCF     ! Temperature at which Phase Change process ends   
                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                           
                    ELSE IF(TDT(I)>=TempTlowPCM .AND. TDT(I)<=TempThighPCM )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                    
                        IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                            (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF(TDT(I)>TempTHighPCM) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                        
                    END IF    
                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF) THEN
                       PhaseChangeState(I)=2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS                               
                    ELSE IF (TDT(I)>=TempTlowPCF .AND. TDT(I)<=TempThighPCF) THEN
                       PhaseChangeState(I)=1
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS                       
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1))THEN
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF (TDT(I)>TempThighPCF) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                    END IF
                 END IF              
                IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1)THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                    PhaseChangeTransition(I) =1
                   PhaseChangeState(I)=0
                ELSE IF(PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I)==0 )THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I)==0)THEN   
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                    PhaseChangeTransition(I) =1
                ELSE 
                    PhaseChangeTransition(I) = 0
                END IF              
				IF (HysteresisFlag == 1) THEN 
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                       
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                          IF(PhaseChangeStateOld(I) == 1.AND.PhaseChangeState(I) == 0) THEN                                                    
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM
                               Tau1 = Tau1M
                               Tau2 = Tau2M
                               DeltaH = DeltaHM
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF
                               Tau1 = Tau1F
                               Tau2 = Tau2F
                               DeltaH = DeltaHF
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1) THEN                                                   
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                                               
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)                         
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                                                  
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))                       
                        END IF 
                    END IF  
                END IF               
                IF(PhaseChangeTransition(I)==0) THEN                 
                    IF (EnthNew(I)==EnthOld(I))  THEN
                        Cp1=CpOld1(I)
                    ELSE
                        Cp1 = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM, EnthOld(I), EnthNew(I))            
                    END IF                  
                ELSE IF(PhaseChangeTransition(I)==1) THEN
                    Cp1 = SpecHeatTransition
                END IF
                Cp1_node(I)=Cp1
            ELSE    ! Regular Material
                Cp1 = Cpo1
                Cp1_node=Cp1
            END IF 
!VE END

      SELECT CASE (CondFDSchemeType)

        CASE (CrankNicholsonSecondOrder)
          TDT(I)=(2.d0*delt*Delx1*QSSFlux*Rlayer2 - delt*Delx1*TD(I) -  &
                delt*kt1*Rlayer2*TD(I) + Cp1*Delx1**2*RhoS1*Rlayer2*TD(I) + delt*kt1*Rlayer2*TD(I-1) +  &
                delt*Delx1*TD(I+1) + delt*kt1*Rlayer2*TDT(I-1) + delt*Delx1*TDT(I+1))/  &
               (delt*Delx1 + delt*kt1*Rlayer2 + Cp1*Delx1**2*RhoS1*Rlayer2)
        CASE (FullyImplicitFirstOrder)
          TDT(I)=(2.d0*delt*Delx1*QSSFlux*Rlayer2  + Cp1*Delx1**2*RhoS1*Rlayer2*TD(I) + 2.d0*delt*kt1*Rlayer2*TDT(I-1) + &
            2.d0*delt*Delx1*TDT(I+1))/ (2.d0*delt*Delx1 + 2.d0*delt*kt1*Rlayer2 + Cp1*Delx1**2*RhoS1*Rlayer2)

      END SELECT

      IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
          (TDT(I) < MinSurfaceTempLimit) ) THEN
        TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!        CALL CheckFDSurfaceTempLimits(I,TDT(I))
      ENDIF

    ELSE  !   Regular or Phase Change on both sides of interface
          !   Consider the various PCM material location cases
      Cp1 = Cpo1    !  Will be changed if PCM
      Cp2 = Cpo2    !  Will be changed if PCM
      IndVarCol = 1  ! temperature
      DepVarCol = 2  ! thermal conductivity

      IF( Sum(MaterialFD(MatLay)%TempEnth(1:3,2)) > 0.0d0  &
          .and. Sum(MaterialFD(MatLay2)%TempEnth(1:3,2)) > 0.0d0) THEN    !  phase change material both layers,  Use TempEnth Data

        Enth1Old = terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TD(I),IndVarCol,DepVarCol)
        Enth2Old = terpld(MaterialFD(MatLay2)%numTempEnth,MaterialFD(MatLay2)%TempEnth,TD(I),IndVarCol,DepVarCol)
        Enth1New = terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TDT(I),IndVarCol,DepVarCol)
        Enth2New = terpld(MaterialFD(MatLay2)%numTempEnth,MaterialFD(MatLay2)%TempEnth,TDT(I),IndVarCol,DepVarCol)

        EnthNew(I) = Enth1New    !  This node really doesn't have an enthalpy, this gives it a value

        IF (ABS(Enth1New-Enth1Old) <= smalldiff .or. ABS(TDT(I)-TD(I)) <= smalldiff)  THEN
          Cp1 = Cpo1
        ELSE
          Cp1 = MAX(Cpo1,(Enth1New -Enth1Old)/(TDT(I)-TD(I)))
        END IF

        IF (ABS(Enth2New-Enth2Old) <= smalldiff .or. ABS(TDT(I)-TD(I)) <= smalldiff)  THEN
          Cp2 = Cpo2
        ELSE
          Cp2 = Max(Cpo2,(Enth2New -Enth2Old)/(TDT(I)-TD(I)))
        END IF

      ELSE IF( SUM(MaterialFD(MatLay)%TempEnth(1:3,2)) > 0.0d0  &
                .and. SUM(MaterialFD(MatLay2)%TempEnth(1:3,2)) < 0.0d0) THEN    !  phase change material Layer1,  Use TempEnth Data

        Enth1Old = terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TD(I),IndVarCol,DepVarCol)
        Enth1New = terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TDT(I),IndVarCol,DepVarCol)
        EnthNew(I) = Enth1New    !  This node really doesn't have an enthalpy, this gives it a value

        IF (ABS(Enth1New-Enth1Old) <= smalldiff .or. ABS(TDT(I)-TD(I)) <= smalldiff)  THEN
          Cp1 = Cpo1
        ELSE
          Cp1 = Max(Cpo1,(Enth1New -Enth1Old)/(TDT(I)-TD(I)))
        END IF

        Cp2 = Cpo2

      ELSE IF( SUM(MaterialFD(MatLay)%TempEnth(1:3,2)) < 0.0d0  &
              .and. SUM(MaterialFD(MatLay2)%TempEnth(1:3,2)) > 0.0d0) THEN    !  phase change material Layer2,  Use TempEnth Data

        Enth2Old = terpld(MaterialFD(MatLay2)%numTempEnth,MaterialFD(MatLay2)%TempEnth,TD(I),IndVarCol,DepVarCol)
        Enth2New = terpld(MaterialFD(MatLay2)%numTempEnth,MaterialFD(MatLay2)%TempEnth,TDT(I),IndVarCol,DepVarCol)
        EnthNew(I) = Enth2New  !  This node really doesn't have an enthalpy, this gives it a value

        IF (ABS(Enth2New-Enth2Old) <= smalldiff .or. ABS(TDT(I)-TD(I)) <= smalldiff)  THEN
          Cp2 = Cpo2
        ELSE
          Cp2 = MAX(Cpo2,(Enth2New -Enth2Old)/(TDT(I)-TD(I)))
        END IF

        Cp1 = Cpo1

      END If  ! Phase Change material check

!VE START 
       IF(Material(MatLay)%DeltaHS>0 .AND. Material(MatLay2)%DeltaHS>0) THEN
                
                TempTlowPCM            =    Material(MatLay)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM        =    Material(MatLay)%TempHighPCM     ! Temperature at which Phase Change process ends
                TempTlowPCM2        =    Material(MatLay2)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM2        =    Material(MatLay2)%TempHighPCM     ! Temperature at which Phase Change process ends
                
                TempTlowPCF            =    Material(MatLay)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF        =    Material(MatLay)%TempHighPCF     ! Temperature at which Phase Change process ends
                TempTlowPCF2        =    Material(MatLay2)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF2        =    Material(MatLay2)%TempHighPCF     ! Temperature at which Phase Change process ends
            
            IF(Material(MatLay)%DeltaHS>0) THEN      
                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                 
            
                    ELSE IF(TDT(I)>=TempTlowPCM .AND. TDT(I)<=TempThighPCM )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF
                        
                        IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                            (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF(TDT(I)>TempTHighPCM) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                        
                    END IF    

                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF) THEN
                       PhaseChangeState(I)=2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                                
                    ELSE IF (TDT(I)>=TempTlowPCF .AND. TDT(I)<=TempThighPCF) THEN
                       PhaseChangeState(I)=-1
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                        
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1))THEN
                           PhaseChangeState(I) = 0
                        END IF

                    ELSE IF (TDT(I)>TempThighPCF) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                    END IF
                 END IF
                 
                IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1)THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                    PhaseChangeTransition(I) =1
                   PhaseChangeState(I)=0
                ELSE IF(PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I)==0 )THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I)==0)THEN   
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                    PhaseChangeTransition(I) =1

                ELSE 
                    PhaseChangeTransition(I) = 0
                END IF
                
				IF (HysteresisFlag == 1) THEN   
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                        
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                          IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                        
                             
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN   
                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM
                               Tau1 = Tau1M
                               Tau2 = Tau2M
                               DeltaH = DeltaHM
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF
                               Tau1 = Tau1F
                               Tau2 = Tau2F
                               DeltaH = DeltaHF
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==2) THEN                        
                            
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)

                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                        
                            
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                        
                            
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                        
                        END IF 
                    END IF  
                END IF
                
                Enth1New = EnthNew(I)
                        
                IF(PhaseChangeTransition(I) == 0 ) THEN
                    IF (Enth1New==Enth1Old)  Then
                        Cp1=CpOld1(I)
                    Else
                        Cp1 = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM, Enth1Old, Enth1New)
                    End IF
                
                ELSE IF (PhaseChangeTransition(I) ==1) THEN                
                    Cp1 = SpecHeatTransition
                END IF
            END IF
            
            IF(Material(MatLay2)%DeltaHS>0) THEN
                
                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM2) THEN
                       PhaseChangeState(I)=2
                        Tc2 = TcM2
                        Tau12 = Material(MatLay2)%Tau1
                        Tau22 = Material(MatLay2)%Tau2
                        DeltaH2 = Material(MatLay2)%DeltaHF                 
            
                    ELSE IF(TDT(I)>=TempTlowPCM2 .AND. TDT(I)<=TempThighPCM2 )THEN
                       PhaseChangeState(I)=-1
                        Tc2 = TcM2
                        Tau12 = Material(MatLay2)%Tau1
                        Tau22 = Material(MatLay2)%Tau2
                        DeltaH2 = Material(MatLay2)%DeltaHF
                        
                        IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                            (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF(TDT(I)>TempTHighPCM2) THEN
                       PhaseChangeState(I)=-2
                        Tc2 = TcM2
                        Tau12 = Material(MatLay2)%Tau1
                        Tau22 = Material(MatLay2)%Tau2
                        DeltaH2 = Material(MatLay2)%DeltaHF                        
                    END IF    

                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF2) THEN
                       PhaseChangeState(I)=2
                        Tc2 = TcF2
                        Tau12 = Material(MatLay2)%Tau1Prime
                        Tau22 = Material(MatLay2)%Tau2Prime
                        DeltaH2 = Material(MatLay2)%DeltaHS
                                
                    ELSE IF (TDT(I)>=TempTlowPCF2 .AND. TDT(I)<=TempThighPCF2) THEN
                       PhaseChangeState(I)=1
                        Tc2 = TcF2
                        Tau12 = Material(MatLay2)%Tau1Prime
                        Tau22 = Material(MatLay2)%Tau2Prime
                        DeltaH2 = Material(MatLay2)%DeltaHS
                        
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1))THEN
                           PhaseChangeState(I) = 0
                        END IF

                    ELSE IF (TDT(I)>TempThighPCF2) THEN
                       PhaseChangeState(I)=-2
                        Tc2 = TcF2
                        Tau12 = Material(MatLay2)%Tau1Prime
                        Tau22 = Material(MatLay2)%Tau2Prime
                        DeltaH2 = Material(MatLay2)%DeltaHS
                    END IF
                 END IF    
                 
                IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1)THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                    PhaseChangeTransition(I) =1
                   PhaseChangeState(I)=0
                ELSE IF(PhaseChangeStateOld(I)==1.AND.PhaseChangeState(I)==0 )THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I)==0)THEN   
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                    PhaseChangeTransition(I) =1

                ELSE 
                    PhaseChangeTransition(I) = 0
                END IF
                 
				IF (HysteresisFlag == 1) THEN     
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc2, Tau12, Tau22, DeltaH2, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc2, Tau12, Tau22, DeltaH2, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                        
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                          IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                        
                             
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN   
                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM2
                               Tau1 = Tau12M
                               Tau2 = Tau22M
                               DeltaH = DeltaH2M
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF2
                               Tau1 = Tau12F
                               Tau2 = Tau22F
                               DeltaH = DeltaH2F
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1) THEN                        
                            
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF2, Tau12F, Tau2F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)

                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                        
                            
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                           
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                        
                            
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            
                        END IF 
                    END IF  
                END IF
                
             Enth2New = EnthNew(I)  
             
                IF(PhaseChangeTransition(I) == 0 ) THEN    
                    IF (Enth2New==Enth2Old)  Then
                        Cp2=CpOld2(I)
                    Else
                        Cp2 = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2, Enth2Old, Enth2New)
                    End IF
                ELSE IF (PhaseChangeTransition(I) ==1) THEN
                    Cp2 = SpecHeatTransition2
                END IF
                
            END IF
           

                Cp1_node(I)=Cp1
                Cp2_node(I)=Cp2
!----------------------------------------------------------------------------------------------------------------------

            ELSE IF(MAterial(MatLay)%DeltaHS > 0 .AND. Material(MatLay2)%DeltaHS<=0) THEN
                
                TempTlowPCM            =    Material(MatLay)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM        =    Material(MatLay)%TempHighPCM     ! Temperature at which Phase Change process ends           
                TempTlowPCF            =    Material(MatLay)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF        =    Material(MatLay)%TempHighPCF     ! Temperature at which Phase Change process ends 
    
                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                 
            
                    ELSE IF(TDT(I)>=TempTlowPCM .AND. TDT(I)<=TempThighPCM )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF
                        
                        IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                            (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF(TDT(I)>TempTHighPCM) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                        
                    END IF    

                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF) THEN
                       PhaseChangeState(I)=2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                                
                    ELSE IF (TDT(I)>=TempTlowPCF .AND. TDT(I)<=TempThighPCF) THEN
                       PhaseChangeState(I)=1
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                        
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1))THEN
                           PhaseChangeState(I) = 0
                        END IF

                    ELSE IF (TDT(I)>TempThighPCF) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcF
                        Tau1 = Material(MatLay)%Tau1Prime
                        Tau2 = Material(MatLay)%Tau2Prime
                        DeltaH = Material(MatLay)%DeltaHS
                    END IF
                 END IF
                
                IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==2)THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                    PhaseChangeTransition(I) =1
                   PhaseChangeState(I)=0
                ELSE IF(PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I)==0 )THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I)==0)THEN   
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                    PhaseChangeTransition(I) =1
					
                ELSE 
                    PhaseChangeTransition(I) = 0
                END IF
                
				IF (HysteresisFlag == 1) THEN     
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                        
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                          IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                        
                             
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN   
                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM
                               Tau1 = Tau1M
                               Tau2 = Tau2M
                               DeltaH = DeltaHM
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF
                               Tau1 = Tau1F
                               Tau2 = Tau2F
                               DeltaH = DeltaHF
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1) THEN                        
                            
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)

                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                        
                            
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                        
                            
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 

                        
                        END IF 
                    END IF  
                END IF

                IF(PhaseChangeTransition(I)==0) THEN
                    
                    IF (EnthNew(I)==EnthOld(I))  THEN
                        Cp1=CpOld1(I)
                    ELSE
                        Cp1 = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM, EnthOld(I), EnthNew(I))            
                    END IF
                    
                ELSE IF(PhaseChangeTransition(I)==1) THEN
                    Cp1 = SpecHeatTransition
                END IF

                Cp1_node(I) = Cp1
                Cp2 = Cpo2
                Cp2_node(I) = Cp2
    
            
            ELSE IF(Material(Matlay)%DeltaHS<=0 .AND. Material(MatLay2)%DeltaHS>0) THEN
                TempTlowPCM2            =    Material(MatLay2)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM2            =    Material(MatLay2)%TempHighPCM     ! Temperature at which Phase Change process ends           
                TempTlowPCF2            =    Material(MatLay2)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF2            =    Material(MatLay2)%TempHighPCF     ! Temperature at which Phase Change process ends 

                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM2) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM2
                        Tau1 = Material(MatLay2)%Tau1
                        Tau2 = Material(MatLay2)%Tau2
                        DeltaH = Material(MatLay2)%DeltaHF                 
            
                    ELSE IF(TDT(I)>=TempTlowPCM2 .AND. TDT(I)<=TempThighPCM2 )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM2
                        Tau1 = Material(MatLay2)%Tau1
                        Tau2 = Material(MatLay2)%Tau2
                        DeltaH = Material(MatLay2)%DeltaHF
                        
                        IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                            (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                           PhaseChangeState(I) = 0
                        END IF
                    ELSE IF(TDT(I)>TempTHighPCM2) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcM2
                        Tau1 = Material(MatLay2)%Tau1
                        Tau2 = Material(MatLay2)%Tau2
                        DeltaH = Material(MatLay2)%DeltaHF                        
                    END IF    

                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF2) THEN
                       PhaseChangeState(I)=2
                        Tc = TcF2
                        Tau1 = Material(MatLay2)%Tau1Prime
                        Tau2 = Material(MatLay2)%Tau2Prime
                        DeltaH = Material(MatLay2)%DeltaHS
                                
                    ELSE IF (TDT(I)>=TempTlowPCF2 .AND. TDT(I)<=TempThighPCF2) THEN
                       PhaseChangeState(I)=1
                        Tc = TcF2
                        Tau1 = Material(MatLay2)%Tau1Prime
                        Tau2 = Material(MatLay2)%Tau2Prime
                        DeltaH = Material(MatLay2)%DeltaHS
                        
                        IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                           (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1))THEN
                           PhaseChangeState(I) = 0
                        END IF

                    ELSE IF (TDT(I)>TempThighPCF2) THEN
                       PhaseChangeState(I)=-2
                        Tc = TcF2
                        Tau1 = Material(MatLay2)%Tau1Prime
                        Tau2 = Material(MatLay2)%Tau2Prime
                        DeltaH = Material(MatLay2)%DeltaHS
                    END IF
                 END IF
                
                IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1)THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                    PhaseChangeTransition(I) =1
                   PhaseChangeState(I)=0
                ELSE IF(PhaseChangeStateOld(I)==1.AND.PhaseChangeState(I)==0 )THEN    
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I)==0)THEN   
                    PhaseChangeTransition(I) =1
                ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                    PhaseChangeTransition(I) =1

                ELSE 
                    PhaseChangeTransition(I) = 0
                END IF
                
				IF (HysteresisFlag == 1) THEN     
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                        
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                          IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                        
                             
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN   
                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM2
                               Tau1 = Tau12M
                               Tau2 = Tau22M
                               DeltaH = DeltaH2M
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF2
                               Tau1 = Tau12F
                               Tau2 = Tau22F
                               DeltaH = DeltaH2F
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau2, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2) 
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1) THEN                        
                            
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)             
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)

                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) == -1 .AND.PhaseChangeState(I) == 0) THEN                        
                            
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                           
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthOld(I) - (SpecHeatTransition2* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                        
                            
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM2, Tau12M, Tau22M, DeltaH2M, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF2, Tau12F, Tau22F, DeltaH2F, SpecHeatSolidPCM2, SpecHeatLiquidPCM2)
                            EnthNew(I) = ((SpecHeatTransition2* TDT(I)) +(EnthRev(I) - (SpecHeatTransition2* Tr(I)))) 
                            
                        
                        END IF 
                    END IF  
                END IF

                IF(PhaseChangeTransition(I)==0) THEN
                    
                    IF (EnthNew(I)==EnthOld(I))  THEN
                        Cp2=CpOld2(I)
                    ELSE
                        Cp2 = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM2, SpecHeatLiquidPCM2, EnthOld(I), EnthNew(I))            
                    END IF
                    
                ELSE IF(PhaseChangeTransition(I)==1) THEN
                    Cp2 = SpecHeatTransition2
                END IF

                Cp2_node(I) = Cp2    
                  Cp1 = Cpo1
                Cp1_node(I) = Cp1
!VE END

      END If  ! Phase change material check

      SELECT CASE (CondFDSchemeType)

        CASE (CrankNicholsonSecondOrder)
        !     Regular Internal Interface Node with Source/sink using Adams Moulton second order
          TDT(I) = (2.d0*delt*Delx1*Delx2*QSSFlux - delt*Delx2*kt1*TD(I) - delt*Delx1*kt2*TD(I) +  &
                 Cp1*Delx1**2.d0*Delx2*RhoS1*TD(I) + Cp2*Delx1*Delx2**2.d0*RhoS2*TD(I) + delt*Delx2*kt1*TD(I-1) +  &
                 delt*Delx1*kt2*TD(I+1) + delt*Delx2*kt1*TDT(I-1) + delt*Delx1*kt2*TDT(I+1))/   &
                 (delt*Delx2*kt1 + delt*Delx1*kt2 + Cp1*Delx1**2.d0*Delx2*RhoS1 + Cp2*Delx1*Delx2**2.d0*RhoS2)

        CASE (FullyImplicitFirstOrder)
        ! first order adams moulton
          TDT(I) = (2.d0*delt*Delx1*Delx2*QSSFlux + &
                 Cp1*Delx1**2.d0*Delx2*RhoS1*TD(I) + Cp2*Delx1*Delx2**2.d0*RhoS2*TD(I) +  &
                 2.d0*delt*Delx2*kt1*TDT(I-1) + 2.d0*delt*Delx1*kt2*TDT(I+1))/   &
                 (2.d0*delt*Delx2*kt1 + 2.d0*delt*Delx1*kt2 + Cp1*Delx1**2.d0*Delx2*RhoS1 + Cp2*Delx1*Delx2**2.d0*RhoS2)

      END SELECT

      IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
          (TDT(I) < MinSurfaceTempLimit) ) THEN
        TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!        CALL CheckFDSurfaceTempLimits(I,TDT(I))
      ENDIF


      IF (Construct(ConstrNum)%SourceSinkPresent .and. Lay == Construct(ConstrNum)%SourceAfterLayer) Then
        TcondFDSourceNode(Surf)= TDT(I) ! transfer node temp to Radiant System
        TempSource(Surf) = TDT(I)  !  Transfer node temp to DataHeatBalSurface  module.

      ENDIF
!+++++++++++++++++++++++++++++++
    END IF   !  end of R-layer and Regular check

  END IF  !End of the CondFD if block


RETURN

END SUBROUTINE IntInterfaceNodeEqns

!VE START@ CpOld
SUBROUTINE InteriorBCEqns(Delt,I,Lay,Surf,T,TT,Rhov,RhoT,RH,TD,TDT,EnthOld,EnthNew,TDReport,CpOld, &
                            PhaseChangeDeltaT,Cp_node,PhaseChangeState,PhaseChangeStateold, &
                           PhaseChangeStateoldold,Tr, PhaseChangeTransition) 
!VE END
          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Richard Liesen
          !       DATE WRITTEN   November, 2003
          !       MODIFIED       B. Griffith, P. Tabares, May 2011, add first order fully implicit, bug fixes, cleanup
          !                      November 2011 P. Tabares fixed problems with adiabatic walls/massless walls
          !                      November 2011 P. Tabares fixed problems PCM stability problems
		  !                      2013-2016, NRGsim Inc., added  Material Property Phase Change Hysteresis Routines.
          !       RE-ENGINEERED  C. O. Pedersen 2006

          ! PURPOSE OF THIS SUBROUTINE:
          ! Calculate the heat transfer at the node on the surfaces inside face (facing zone)

          ! METHODOLOGY EMPLOYED:
          ! <description>

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
  USE DataHeatBalFanSys, ONLY: Mat, ZoneAirHumRat, QHTRadSysSurf, QHWBaseboardSurf, QSteamBaseboardSurf, QElecBaseboardSurf
  USE DataSurfaces,      ONLY: HeatTransferModel_CondFD
  IMPLICIT NONE ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
  INTEGER, INTENT(IN)  :: Delt  ! Time Increment
  INTEGER, INTENT(IN)  :: I     ! Node Index
  INTEGER, INTENT(IN)  :: Lay   ! Layer Number for Construction
  INTEGER, INTENT(IN)  :: Surf  ! Surface number
  REAL(r64),DIMENSION(:), INTENT(In)    :: T     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF (Old).
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TT    !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF (New).
  REAL(r64),DIMENSION(:), INTENT(In)    :: Rhov     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RhoT  !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(In)    :: TD     !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TDT    !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: RH    !INSIDE SURFACE TEMPERATURE OF EACH HEAT TRANSFER SURF.
  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthOld    ! Old Nodal enthalpy
  REAL(r64),DIMENSION(:), INTENT(InOut) :: EnthNew    ! New Nodal enthalpy
  REAL(r64),DIMENSION(:), INTENT(InOut) :: TDreport    ! Temperature value from previous HeatSurfaceHeatManager titeration's value
!VE START
  REAL(r64) :: Tc
  REAL(r64) :: DeltaH
  REAL(r64),Dimension(100)  :: EnthalpyF  
  REAL(r64),Dimension(100)  :: EnthalpyM 
  REAL(r64),Dimension(:), Intent(InOut) :: CpOld      ! Old Nodal Specific Heat
  Real(r64),Dimension(:), Intent(InOut) :: PhaseChangeDeltaT 
  INTEGER,Dimension(:), Intent(InOut)   :: PhaseChangeTransition 
  REAL(r64),Dimension(:), Intent(InOut) :: Cp_node      ! Nodal Specific Heat
  Integer,Dimension(:), Intent(InOut)   :: PhaseChangeState
  Integer,Dimension(:), Intent(InOut)   :: PhaseChangeStateold
  Integer,Dimension(:), Intent(InOut)   :: PhaseChangeStateoldold
  REAL(r64),Dimension(:), Intent(InOut) :: Tr ! PhaseChangeTemperatureReverse
  REAL(r64), Dimension(100) :: EnthRev
!VE END
          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS:
          ! na

          ! DERIVED TYPE DEFINITIONS:
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
  REAL(r64) :: NetLWRadToSurfFD !Net interior long wavelength radiation to surface from other surfaces
  REAL(r64) :: QRadSWInFD    !Short wave radiation absorbed on inside of opaque surface
  REAL(r64) :: QHtRadSysSurfFD  ! Current radiant heat flux at a surface due to the presence of high temperature radiant heaters
  Real(r64) :: QHWBaseboardSurfFD  ! Current radiant heat flux at a surface due to the presence of hot water baseboard heaters
  Real(r64) :: QSteamBaseboardSurfFD  ! Current radiant heat flux at a surface due to the presence of steam baseboard heaters
  Real(r64) :: QElecBaseboardSurfFD  ! Current radiant heat flux at a surface due to the presence of electric baseboard heaters
  REAL(r64) :: QRadThermInFD !Thermal radiation absorbed on inside surfaces
  REAL(r64) :: Delx
  REAL(r64), PARAMETER :: IterDampConst = 5.0d0  ! Damping constant for inside surface temperature iterations. Only used for massless (R-value only) Walls

  INTEGER    :: ConstrNum
  INTEGER    :: MatLay
  INTEGER    :: IndVarCol
  INTEGER    :: DepVarCol

  REAL(r64)  :: kto
  REAL(r64)  :: kt1
  REAL(r64)  :: kt
  REAL(r64)  :: Cp
  REAL(r64)  :: Cpo
  REAL(r64)  :: RhoS
  REAL(r64)  :: Tia
  REAL(r64)  :: Rhovi
  REAL(r64)  :: hmassi
  REAL(r64)  :: hconvi

  REAL(r64)  :: Rlayer
  REAL(r64)  :: SigmaRLoc
  REAL(r64)  :: SigmaCLoc
  REAL(r64)  :: QNetSurfInside
  !VE START
    REAL(r64)         :: TempTlowPCM
    REAL(r64)         :: TempThighPCM
    REAL(r64)         :: TempTlowPCF
    REAL(r64)         :: TempThighPCF
    REAL(r64)         :: SpecHeatSolidPCM
    REAL(r64)         :: SpecHeatLiquidPCM
    REAL(r64)         :: SpecHeatTransition
    !*****************************************************************************
    ! These are variables that explicitly hold the freezing and melting curve 
    ! properties and are used  in the transition region only
    REAL(r64)         :: Tau1M ! Melting region low
    REAL(r64)         :: Tau2M ! Melting region high
    REAL(r64)         :: Tau1F ! Freezing region low 
    REAL(r64)         :: Tau2F ! Freezing region high 
    REAL(r64)         :: DeltaHM ! Latent heat of Melting
    REAL(r64)         :: DeltaHF ! Latent heat of Freezing
    !********************************************************************************
!VE END  

  ConstrNum = Surface(surf)%Construction
  SigmaRLoc = SigmaR(ConstrNum)
  SigmaCLoc = SigmaC(ConstrNum)

  !Set the internal conditions to local variables
  NetLWRadToSurfFD      = NetLWRadToSurf(surf)
  QRadSWInFD            = QRadSWInAbs(surf)
  QHtRadSysSurfFD       = QHtRadSysSurf(surf)
  QHWBaseboardSurfFD    = QHWBaseboardSurf(surf)
  QSteamBaseboardSurfFD = QSteamBaseboardSurf(surf)
  QElecBaseboardSurfFD  = QElecBaseboardSurf(surf)
  QRadThermInFD         = QRadThermInAbs(Surf)

  !Boundary Conditions from Simulation for Interior
  hconvi = HConvInFD(surf)
  hmassi = HMassConvInFD(surf)

  Tia    = Mat(Surface(Surf)%Zone)
  rhovi  = RhoVaporAirIn(surf)

!++++++++++++++++++++++++++++++++++++++++++++++++++++++
   !    Do all the nodes in the surface   Else will switch to SigmaR,SigmaC
  IF (Surface(Surf)%HeatTransferAlgorithm == HeatTransferModel_CondFD) THEN

    MatLay = Construct(ConstrNum)%LayerPoint(Lay)
!VE START 
    TcM = Material(MatLay)%Tm
    Tau1 = Material(MatLay)%Tau1
    Tau2 = Material(MatLay)%Tau2
    TempTlowPCM       = TcM-Tau1        ! Temperature at which Phase Change process starts
    TempThighPCM      = TcM+Tau2    ! Temperature at which Phase Change process ends 
    Material(MatLay)%TempLowPCM = TempTlowPCM            
    Material(MatLay)%TempHighPCM= TempThighPCM
        
    TcF = Material(MatLay)%Tf
    Tau1F = Material(MatLay)%Tau1Prime
    Tau2F = Material(MatLay)%Tau2Prime
    TempTlowPCF       = TcF-Tau1F        ! Temperature at which Phase Change process starts
    TempThighPCF      = TcF+Tau2F    ! Temperature at which Phase Change process ends         
    Material(MatLay)%TempLowPCF = TempTlowPCF            
    Material(MatLay)%TempHighPCF= TempThighPCF
   
    SpecHeatSolidPCM  = Material(MatLay)%CpSolid
    SpecHeatLiquidPCM = Material(MatLay)%CpLiquid
    SpecHeatTransition = (SpecHeatSolidPCM+SpecHeatLiquidPCM)/2
    
    DeltaHM = Material(MatLay)%DeltaHF
    DeltaHF = Material(MatLay)%DeltaHS
    Tau1M = Material(MatLay)%Tau1
    Tau2M = Material(MatLay)%Tau2
    Tau1F = Material(MatLay)%Tau1Prime
    Tau2F = Material(MatLay)%Tau2Prime
 !VE END
     !  Set Thermal Conductivity.  Can be constant, simple linear temp dep or multiple linear segment temp function dep.
    kto = Material(MatLay)%Conductivity   !  20C base conductivity
    kt1 = MaterialFD(MatLay)%tk1  !  linear coefficient (normally zero)
    kt  = kto + kt1*((TDT(I)+TDT(i-1))/2.d0 - 20.d0)


    IF( SUM(MaterialFD(MatLay)%TempCond(1:3,2)) >= 0.0d0) THEN ! Multiple Linear Segment Function

      DepVarCol= 2  ! thermal conductivity
      IndVarCol=1  !temperature
          !  Use average  of surface and first node temp for determining k
      kt  = terpld(MaterialFD(MatLay)%numTempCond,MaterialFD(MatLay)%TempCond,(TDT(I)+TDT(I-1))/2.0d0 ,IndVarCol,DepVarCol)

    ENDIF


    RhoS = Material(MatLay)%Density
    Cpo = Material(MatLay)%SpecHeat
    Cp  = Cpo  !  Will be changed if PCM
    Delx = ConstructFD(ConstrNum)%Delx(Lay)

    !Calculate the Dry Heat Conduction Equation

    Rlayer = Material(MatLay)%Resistance
    If (Material(MatLay)%ROnly .or. Material(MatLay)%Group == 1 ) THEN  ! R Layer or Air Layer
            !  Use algebraic equation for TDT based on R

      IF (Surface(Surf)%ExtBoundCond > 0 .and. i==1) THEN  !this is for an adiabatic partition

        TDT(I)=(NetLWRadToSurfFD*Rlayer+QHtRadSysSurfFD*Rlayer + QHWBaseboardSurfFD*Rlayer + QSteamBaseboardSurfFD*Rlayer + &
                    QElecBaseboardSurfFD*Rlayer +  QRadSWInFD*Rlayer + QRadThermInFD*Rlayer +   &
                       TDT(I+1) + hconvi*Rlayer*Tia+TDreport(I)*IterDampConst*Rlayer)/(1.0d0 + hconvi*Rlayer+IterDampConst*Rlayer)


      ELSE ! regular wall
        TDT(I)=(NetLWRadToSurfFD*Rlayer+QHtRadSysSurfFD*Rlayer + QHWBaseboardSurfFD*Rlayer + QSteamBaseboardSurfFD*Rlayer + &
                    QElecBaseboardSurfFD*Rlayer + QRadSWInFD*Rlayer + QRadThermInFD*Rlayer +   &
                       TDT(I-1) + hconvi*Rlayer*Tia+TDreport(I)*IterDampConst*Rlayer)/(1.0d0 + hconvi*Rlayer+IterDampConst*Rlayer)
      ENDIF

      IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
          (TDT(I) < MinSurfaceTempLimit) ) THEN
        TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!        CALL CheckFDSurfaceTempLimits(I,TDT(I))
      ENDIF

    ELSE  !  Regular or PCM


      IF( Sum(MaterialFD(MatLay)%TempEnth(1:3,2)) >= 0.0d0) THEN    !  phase change material,  Use TempEnth Data

        DepVarCol= 2  ! enthalpy
        IndVarCol=1  !temperature

        EnthOld(I) =terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TD(I),IndVarCol,DepVarCol)

        EnthNew(I) =terpld(MaterialFD(MatLay)%numTempEnth,MaterialFD(MatLay)%TempEnth,TDT(I),IndVarCol,DepVarCol)
        IF (ABS(EnthNew(I)-EnthOld(I)) <= smalldiff .or. ABS(TDT(I)-TD(I)) <= smalldiff)  THEN
          Cp = Cpo
        ELSE
          Cp = MAX(Cpo,(EnthNew(I) -EnthOld(I))/(TDT(I)-TD(I)))
        END IF

END IF
!VE START
           IF(Material(Matlay)%DeltaHS >0) THEN                                              
				
                TempTlowPCM            =    Material(MatLay)%TempLowPCM        ! Temperature at which Phase Change process starts
                TempThighPCM        =    Material(MatLay)%TempHighPCM     ! Temperature at which Phase Change process ends           
                TempTlowPCF            =    Material(MatLay)%TempLowPCF        ! Temperature at which Phase Change process starts
                TempThighPCF        =    Material(MatLay)%TempHighPCF     ! Temperature at which Phase Change process ends 

                IF (PhaseChangeDeltaT(I)<0) THEN
                    IF(TDT(I)<TempTlowPCM) THEN
                       PhaseChangeState(I)=2
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF                 
            
                    ELSE IF(TDT(I)>=TempTlowPCM .AND. TDT(I)<=TempThighPCM )THEN
                       PhaseChangeState(I)=-1
                        Tc = TcM
                        Tau1 = Material(MatLay)%Tau1
                        Tau2 = Material(MatLay)%Tau2
                        DeltaH = Material(MatLay)%DeltaHF
                        
                         IF((PhaseChangeStateOld(I)==1 .AND.PhaseChangeState(I) == -1) .OR. &
                             (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == -1)) THEN
                            PhaseChangeState(I) = 0
                         END IF
                    ELSE IF(TDT(I)>TempTHighPCM) THEN
                       PhaseChangeState(I)=-2
                       Tc = TcM
                       Tau1 = Material(MatLay)%Tau1
                       Tau2 = Material(MatLay)%Tau2
                       DeltaH = Material(MatLay)%DeltaHF                        
                    END IF    

                 ELSE IF(PhaseChangeDeltaT(I)>0) THEN
                    IF (TDT(I)<TempTLowPCF) THEN
                       PhaseChangeState(I)=2
                       Tc = TcF
                       Tau1 = Material(MatLay)%Tau1Prime
                       Tau2 = Material(MatLay)%Tau2Prime
                       DeltaH = Material(MatLay)%DeltaHS
                                
                    ELSE IF (TDT(I)>=TempTlowPCF .AND. TDT(I)<=TempThighPCF) THEN
                       PhaseChangeState(I)=1
                       Tc = TcF
                       Tau1 = Material(MatLay)%Tau1Prime
                       Tau2 = Material(MatLay)%Tau2Prime
                       DeltaH = Material(MatLay)%DeltaHS
                       IF((PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I) == 1) .OR. &
                          (PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I) == 1)) THEN 
                          PhaseChangeState(I) = 0
                       END IF
                    ELSE IF (TDT(I)>TempThighPCF) THEN
                       PhaseChangeState(I)=-2
                       Tc = TcF
                       Tau1 = Material(MatLay)%Tau1Prime
                       Tau2 = Material(MatLay)%Tau2Prime
                       DeltaH = Material(MatLay)%DeltaHS
                    END IF
                 END IF
                 
                 IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1)THEN    
                    PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==1)THEN  
                    PhaseChangeTransition(I) =1
                    PhaseChangeState(I)=0
                 ELSE IF(PhaseChangeStateOld(I)==1.AND.PhaseChangeState(I)==0 )THEN    
                     PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==-1 .AND.PhaseChangeState(I)==0)THEN   
                     PhaseChangeTransition(I) =1
                 ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==0)THEN    
                     PhaseChangeTransition(I) =1
                 ELSE 
                     PhaseChangeTransition(I) = 0
                 END IF                   
                
				IF (HysteresisFlag == 1) THEN    
                    IF(PhaseChangeTransition(I) == 0)THEN
                        EnthOld(I) = SpecEnthalpy(I,TD(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM)                    
                        EnthNew(I) = SpecEnthalpy(I,TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                        
                    ELSE IF(PhaseChangeTransition(I) ==1) THEN     
                         IF(PhaseChangeStateOld(I) == 1 .AND.PhaseChangeState(I) == 0) THEN                        
                             
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                        !------------------------------------------------------------------------------------------------------------
                            IF (EnthNew(I) < EnthRev(I) .AND. EnthNew(I) >= EnthalpyF(I) .AND. TDT(I) <= TD(I)) THEN
                               PhaseChangeState(I) = 1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                         !---------------DONOT CHANGE TO ENTHREV----------------!
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition*  TD(I))))  
                            !------------------------------------------------------------------!
                            ELSE IF (EnthNew(I) < EnthalpyF(I).AND. TDT(I) > Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition*  Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I) .AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            END IF
                         !--------------------------------------------------------------------------------------------------------------   
                        ELSE IF (PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 0) THEN   
                            
                            IF(TDT(I) < Tr(I)) THEN
                               Tc = TcM
                               Tau1 = Tau1M
                               Tau2 = Tau2M
                               DeltaH = DeltaHM
                            ELSE IF(TDT(I) > Tr(I)) THEN
                               Tc = TcF
                               Tau1 = Tau1F
                               Tau2 = Tau2F
                               DeltaH = DeltaHF
                            END IF
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM) 
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (TDT(I) < Tr(I).AND. EnthNew(I) > EnthalpyF(I)) THEN
                               PhaseChangeState(I) = 1                    
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. (TDT(I)<TD(I) .OR. TDT(I)>TD(I))) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I).AND. EnthNew(I) > EnthOld(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
                        !-----------------------------------------------------------------------------------------------------------------    
                        ELSE IF(PhaseChangeStateOld(I)==0 .AND.PhaseChangeState(I)==-1) THEN                        
                            
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)             
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)

                            IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) <= EnthalpyM(I).AND. TDT(I) >= TD(I)) THEN
                               PhaseChangeState(I)= -1
                                EnthNew(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            END IF
                        !--------------------------------------------------------------------------------------------------------                                  
                        ELSE IF(PhaseChangeStateOld(I) ==  -1.AND.PhaseChangeState(I) == 0) THEN                                
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I)))) 
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                           
                            IF (EnthNew(I) < EnthOld(I) .AND. TDT(I) < TD(I)) THEN
                               PhaseChangeState(I) = 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthOld(I) - (SpecHeatTransition* TD(I))))
                            ELSE IF(EnthNew(I) < EnthalpyF(I) .AND. EnthNew(I) > EnthalpyM(I) .AND. TDT(I) <TD(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            ELSE IF (EnthNew(I) >= EnthalpyF(I).AND. TDT(I) <= Tr(I)) THEN
                               PhaseChangeState(I)= 0
                                EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I))))
                            END IF
 !----------------------------------------------------------------------------------------------------------------------------------                                          
                        ELSE IF(PhaseChangeStateOld(I) == 0 .AND.PhaseChangeState(I) == 1) THEN                        
                            
                            EnthalpyM(I) = SpecEnthalpy(I,TDT(I), TcM, Tau1M, Tau2M, DeltaHM, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthalpyF(I) = SpecEnthalpy(I,TDT(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthRev(I) = SpecEnthalpy(I,Tr(I), TcF, Tau1F, Tau2F, DeltaHF, SpecHeatSolidPCM, SpecHeatLiquidPCM)
                            EnthNew(I) = ((SpecHeatTransition* TDT(I)) +(EnthRev(I) - (SpecHeatTransition* Tr(I)))) 
                            
                       
                        END IF 
                    END IF  
                END IF
                IF (EnthNew(I)==EnthOld(I))  Then
                    Cp=CpOld(I)
                Else
                    Cp = SpecHeat(I, TD(I), TDT(I), Tc, Tau1, Tau2, DeltaH, SpecHeatSolidPCM, SpecHeatLiquidPCM, EnthOld(I), EnthNew(I))
                    
                End IF

                Cp_node(I)=Cp
!VE END
      ELSE  ! Not phase change material
        Cp= Cpo

      END IF  ! Phase change material check

      IF (Surface(Surf)%ExtBoundCond > 0 .and. i==1) THEN !this is for an adiabatic or interzone partition
        SELECT CASE (CondFDSchemeType)

        CASE (CrankNicholsonSecondOrder)
          ! Adams-Moulton second order
          TDT(I)=(2.d0*Delt*Delx*NetLWRadToSurfFD + 2.d0*Delt*Delx*QHtRadSysSurfFD + 2.d0*Delt*Delx*QHWBaseboardSurfFD + &
                 2.d0*Delt*Delx*QSteamBaseboardSurfFD + 2.d0*Delt*Delx*QElecBaseboardSurfFD + &
                 2.d0*Delt*Delx*QRadSWInFD + 2.d0*Delt*Delx*QRadThermInFD -  &
                  Delt*Delx*hconvi*TD(I) - Delt*kt*TD(I) + Cp*Delx**2*RhoS*TD(I) +  &
                  Delt*kt*TD(I+1) + Delt*kt*TDT(I+1) + 2.d0*Delt*Delx*hconvi*Tia)/  &
                  (Delt*Delx*hconvi + Delt*kt + Cp*Delx**2*RhoS)

        CASE (FullyImplicitFirstOrder)
        ! Adams-Moulton First order
          TDT(I)=(2.d0*Delt*Delx*NetLWRadToSurfFD + 2.d0*Delt*Delx*QHtRadSysSurfFD + 2.d0*Delt*Delx*QHWBaseboardSurfFD + &
                 2.d0*Delt*Delx*QSteamBaseboardSurfFD + 2.d0*Delt*Delx*QElecBaseboardSurfFD + &
                 2.d0*Delt*Delx*QRadSWInFD + 2.d0*Delt*Delx*QRadThermInFD +  &
                  Cp*Delx**2*RhoS*TD(I) + 2.d0*Delt*kt*TDT(I+1) + 2.d0*Delt*Delx*hconvi*Tia)/  &
                  (2.d0*Delt*Delx*hconvi + 2.d0*Delt*kt + Cp*Delx**2*RhoS)
        END SELECT

      ELSE ! for regular or interzone walls
        SELECT CASE (CondFDSchemeType)

        CASE (CrankNicholsonSecondOrder)
          TDT(I)=(2.d0*Delt*Delx*NetLWRadToSurfFD + 2.d0*Delt*Delx*QHtRadSysSurfFD + 2.d0*Delt*Delx*QHWBaseboardSurfFD + &
               2.d0*Delt*Delx*QSteamBaseboardSurfFD + 2.d0*Delt*Delx*QElecBaseboardSurfFD + &
               2.d0*Delt*Delx*QRadSWInFD + 2.d0*Delt*Delx*QRadThermInFD -  &
                Delt*Delx*hconvi*TD(I) - Delt*kt*TD(I) + Cp*Delx**2*RhoS*TD(I) +  &
                Delt*kt*TD(I-1) + Delt*kt*TDT(I-1) + 2.d0*Delt*Delx*hconvi*Tia)/  &
                (Delt*Delx*hconvi + Delt*kt + Cp*Delx**2*RhoS)
        CASE (FullyImplicitFirstOrder)
          TDT(I)=(2.d0*Delt*Delx*NetLWRadToSurfFD + 2.d0*Delt*Delx*QHtRadSysSurfFD + 2.d0*Delt*Delx*QHWBaseboardSurfFD + &
               2.d0*Delt*Delx*QSteamBaseboardSurfFD + 2.d0*Delt*Delx*QElecBaseboardSurfFD + &
               2.d0*Delt*Delx*QRadSWInFD + 2.d0*Delt*Delx*QRadThermInFD +  &
                Cp*Delx**2*RhoS*TD(I) + 2.d0*Delt*kt*TDT(I-1) + 2.d0*Delt*Delx*hconvi*Tia)/  &
                (2.d0*Delt*Delx*hconvi + 2.d0*Delt*kt + Cp*Delx**2*RhoS)
        END SELECT
      ENDIF

      IF ((TDT(I) > MaxSurfaceTempLimit) .OR. &
          (TDT(I) < MinSurfaceTempLimit) ) THEN
        TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check
!        CALL CheckFDSurfaceTempLimits(I,TDT(I))
      ENDIF
!      TDT(I) = Max(MinSurfaceTempLimit,Min(MaxSurfaceTempLimit,TDT(I)))  !  +++++ Limit Check

!  Pass inside conduction Flux [W/m2] to DataHeatBalanceSurface array
!          OpaqSurfInsFaceConductionFlux(Surf)= (TDT(I-1)-TDT(I))*kt/Delx
    END IF  ! Regular or R layer

  END IF   !  End of Regular node or SigmaR SigmaC option


  QNetSurfInside= - (NetLWRadToSurfFD + QHtRadSysSurfFD + QRadSWInFD + QRadThermInFD + QHWBaseboardSurfFD  + &
             QSteamBaseboardSurfFD+QElecBaseboardSurfFD+hconvi*(-TDT(I) + Tia))
! note -- no change ref: CR8575
!feb2012  QNetSurfInside=NetLWRadToSurfFD + QHtRadSysSurfFD + QRadSWInFD + QRadThermInFD + QHWBaseboardSurfFD  + &
!feb2012             QSteamBaseboardSurfFD+QElecBaseboardSurfFD+hconvi*(-TDT(I) + Tia)

    !  Pass inside conduction Flux [W/m2] to DataHeatBalanceSurface array
!VE START HEAT FLUX OUTPUT
OpaqSurfInsFaceConductionFlux(Surf)= QNetSurfInside
!VE END
!  QFluxZoneToInSurf(Surf) = QNetSurfInside
  OpaqSurfInsFaceConduction(Surf)=QNetSurfInside*Surface(Surf)%Area   !for reporting as in CTF, PT

RETURN

END SUBROUTINE InteriorBCEqns
!VE START
REAL(r64) FUNCTION SpecEnthalpy(I, T, Tc, Tau1, Tau2, DeltaH, CpSolid, CpLiquid)

                                           
REAL(r64), INTENT(IN)   ::  T           ! Nodal Temperature
REAL(r64), INTENT(IN)   ::  Tc          ! Critical (Melting/Freezing) Temperature of PCM
REAL(r64), INTENT(IN)   ::  Tau1        ! Width of Melting Zone low
REAL(r64), INTENT(IN)   ::  Tau2        ! Width of Melting Zone high
REAL(r64), INTENT(IN)   ::  DeltaH      ! Latent Heat Stored in PCM During Phase Change
REAL(r64), INTENT(IN)   ::  CpSolid     ! Specific Heat of PCM in Solid State
REAL(r64), INTENT(IN)   ::  CpLiquid    ! Specific Heat of PCM in Liquid State
INTEGER ,  INTENT(IN)   ::  I           ! Node Counter

! INTERMEDIATE VARIABLES
REAL                    ::  Cp1
REAL                    ::  Cp2
REAL(r64)               ::  Eta1
REAL(r64)               ::  Eta2


Cp1 = CpSolid
Cp2 = CpLiquid

    Eta1 = (DeltaH /2)* EXP(-2* ABS(T - Tc)/Tau1)
    Eta2 = (DeltaH /2)* EXP(-2* ABS(T - Tc)/Tau2)

IF (T<=Tc) THEN
    SpecEnthalpy = ((Cp1*T)+ Eta1)
ELSE IF(T>Tc)THEN
    SpecEnthalpy = ((Cp1*Tc) + DeltaH + Cp2*(T-Tc)- Eta2)
END IF

END FUNCTION SpecEnthalpy

REAL(r64) FUNCTION SpecHeat(I, Told, Tnew, Tc, Tau1, Tau2, DeltaH, CpSolid, CpLiquid, EnthalpyOld, EnthalpyNew) 

INTEGER, INTENT(IN)     ::  I                   ! Node Counter
REAL(r64), INTENT(IN)   ::  Told                ! Previos Timestep Nodal Temperature
REAL(r64), INTENT(IN)   ::  Tnew                ! Current Timestep Nodal Temperature
REAL(r64), INTENT(IN)   ::  Tc                  ! Critical (Melting/Freezing) Temperature of PCM
REAL(r64), INTENT(IN)   ::  Tau1                ! Width of Melting Zone low
REAL(r64), INTENT(IN)   ::  Tau2                ! Width of Melting Zone high
REAL(r64), INTENT(IN)   ::  DeltaH              ! Latent Heat Stored in PCM During Phase Change
REAL(r64), INTENT(IN)   ::  CpSolid             ! Specific Heat of PCM in Solid State
REAL(r64), INTENT(IN)   ::  CpLiquid            ! Specific Heat of PCM in Liquid State
REAL(r64), INTENT(IN)   ::  EnthalpyOld         ! Previos Timestep Nodal Enthalpy
REAL(r64), INTENT(IN)   ::  EnthalpyNew         ! Current Timestep Nodal Enthalpy

! INTERMEDIATE VARIABLES
REAL                    ::  Cp1
REAL                    ::  Cp2
REAL(r64)               ::  DEta1
REAL(r64)               ::  DEta2
REAL(r64)               ::  T
REAL(r64)               ::  Tau
Real(r64)               ::  DelH

Cp1 =  CpSolid
Cp2 =  CpLiquid
DelH =  DeltaH
T = Tnew

 DEta1 = -(DelH * (T-Tc) * EXP(-2*ABS(T-Tc)/Tau1))/(Tau1 * ABS(T-Tc))
 DEta2 = (DelH * (T-Tc) * EXP(-2*ABS(T-Tc)/Tau2))/(Tau2 * ABS(T-Tc))

IF (T<Tc) THEN
    SpecHeat = (Cp1 + DEta1)
ELSE IF((T==Tc))THEN
    SpecHeat = (EnthalpyNew-EnthalpyOld) / (Tnew - TOld)
ELSE IF(T>Tc)THEN
    SpecHeat = (Cp2 + DEta2)
END IF
    
END FUNCTION SpecHeat 
!VE END
SUBROUTINE CheckFDSurfaceTempLimits(SurfNum,CheckTemperature)

          ! SUBROUTINE INFORMATION:
          !       AUTHOR         Linda Lawrie
          !       DATE WRITTEN   August 2012
          !       MODIFIED       na
          !       RE-ENGINEERED  na

          ! PURPOSE OF THIS SUBROUTINE:
          ! Provides a single entry point for checking surface temperature limits as well as
          ! setting up for recurring errors if too low or too high.

          ! METHODOLOGY EMPLOYED:
          ! Use methodology similar to HBSurfaceManager

          ! REFERENCES:
          ! na

          ! USE STATEMENTS:
  USE General, ONLY: RoundSigDigits
  USE DataAirFlowNetwork, ONLY: SimulateAirFlowNetwork,AirflowNetworkControlSimple

  IMPLICIT NONE ! Enforce explicit typing of all variables in this routine

          ! SUBROUTINE ARGUMENT DEFINITIONS:
  INTEGER, INTENT(IN)   :: SurfNum  ! surface number
  REAL(R64), INTENT(IN) :: CheckTemperature  ! calculated temperature, not reset

          ! SUBROUTINE PARAMETER DEFINITIONS:
          ! na

          ! INTERFACE BLOCK SPECIFICATIONS:
          ! na

          ! DERIVED TYPE DEFINITIONS:
          ! na

          ! SUBROUTINE LOCAL VARIABLE DECLARATIONS:
  INTEGER :: ZoneNum

  ZoneNum=Surface(SurfNum)%Zone

!      IF ((TH(SurfNum,1,2) > MaxSurfaceTempLimit) .OR. &
!          (TH(SurfNum,1,2) < MinSurfaceTempLimit) ) THEN
  IF (WarmupFlag) WarmupSurfTemp=WarmupSurfTemp+1
  IF (.not. WarmupFlag  .or. (WarmupFlag .and. WarmupSurfTemp > 10) .or. DisplayExtraWarnings) THEN
    IF (CheckTemperature < MinSurfaceTempLimit) THEN
      IF (Surface(SurfNum)%LowTempErrCount == 0) THEN
        CALL ShowSevereMessage('Temperature (low) out of bounds ['//TRIM(RoundSigDigits(CheckTemperature,2))//  &
                           '] for zone="'//trim(Zone(ZoneNum)%Name)//'", for surface="'//TRIM(Surface(SurfNum)%Name)//'"')
        CALL ShowContinueErrorTimeStamp(' ')
        IF (.not. Zone(ZoneNum)%TempOutOfBoundsReported) THEN
          CALL ShowContinueError('Zone="'//trim(Zone(ZoneNum)%Name)//'", Diagnostic Details:')
          IF (Zone(ZoneNum)%FloorArea > 0.0d0) THEN
            CALL ShowContinueError('...Internal Heat Gain ['//  &
                 trim(RoundSigDigits(Zone(ZoneNum)%InternalHeatGains/Zone(ZoneNum)%FloorArea,3))//'] W/m2')
          ELSE
            CALL ShowContinueError('...Internal Heat Gain (no floor) ['//  &
                 trim(RoundSigDigits(Zone(ZoneNum)%InternalHeatGains,3))//'] W')
          ENDIF
          IF (SimulateAirflowNetwork <= AirflowNetworkControlSimple) THEN
            CALL ShowContinueError('...Infiltration/Ventilation ['//  &
                   trim(RoundSigDigits(Zone(ZoneNum)%NominalInfilVent,3))//'] m3/s')
            CALL ShowContinueError('...Mixing/Cross Mixing ['//  &
                   trim(RoundSigDigits(Zone(ZoneNum)%NominalMixing,3))//'] m3/s')
          ELSE
            CALL ShowContinueError('...Airflow Network Simulation: Nominal Infiltration/Ventilation/Mixing not available.')
          ENDIF
          IF (Zone(ZoneNum)%isControlled) THEN
            CALL ShowContinueError('...Zone is part of HVAC controlled system.')
          ELSE
            CALL ShowContinueError('...Zone is not part of HVAC controlled system.')
          ENDIF
          Zone(ZoneNum)%TempOutOfBoundsReported=.true.
        ENDIF
        CALL ShowRecurringSevereErrorAtEnd('Temperature (low) out of bounds for zone='//trim(Zone(ZoneNum)%Name)//  &
                       ' for surface='//TRIM(Surface(SurfNum)%Name),  &
                       Surface(SurfNum)%LowTempErrCount,ReportMaxOf=CheckTemperature,ReportMaxUnits='C',  &
                       ReportMinOf=CheckTemperature,ReportMinUnits='C')
      ELSE
        CALL ShowRecurringSevereErrorAtEnd('Temperature (low) out of bounds for zone='//trim(Zone(ZoneNum)%Name)//  &
                       ' for surface='//TRIM(Surface(SurfNum)%Name),  &
                       Surface(SurfNum)%LowTempErrCount,ReportMaxOf=CheckTemperature,ReportMaxUnits='C',  &
                       ReportMinOf=CheckTemperature,ReportMinUnits='C')
      ENDIF
    ELSE
      IF (Surface(SurfNum)%HighTempErrCount == 0) THEN
        CALL ShowSevereMessage('Temperature (high) out of bounds ('//TRIM(RoundSigDigits(CheckTemperature,2))//  &
                           '] for zone="'//trim(Zone(ZoneNum)%Name)//'", for surface="'//TRIM(Surface(SurfNum)%Name)//'"')
        CALL ShowContinueErrorTimeStamp(' ')
        IF (.not. Zone(ZoneNum)%TempOutOfBoundsReported) THEN
          CALL ShowContinueError('Zone="'//trim(Zone(ZoneNum)%Name)//'", Diagnostic Details:')
          IF (Zone(ZoneNum)%FloorArea > 0.0d0) THEN
            CALL ShowContinueError('...Internal Heat Gain ['//  &
                 trim(RoundSigDigits(Zone(ZoneNum)%InternalHeatGains/Zone(ZoneNum)%FloorArea,3))//'] W/m2')
          ELSE
            CALL ShowContinueError('...Internal Heat Gain (no floor) ['//  &
                 trim(RoundSigDigits(Zone(ZoneNum)%InternalHeatGains,3))//'] W')
          ENDIF
          IF (SimulateAirflowNetwork <= AirflowNetworkControlSimple) THEN
            CALL ShowContinueError('...Infiltration/Ventilation ['//  &
                   trim(RoundSigDigits(Zone(ZoneNum)%NominalInfilVent,3))//'] m3/s')
            CALL ShowContinueError('...Mixing/Cross Mixing ['//  &
                   trim(RoundSigDigits(Zone(ZoneNum)%NominalMixing,3))//'] m3/s')
          ELSE
            CALL ShowContinueError('...Airflow Network Simulation: Nominal Infiltration/Ventilation/Mixing not available.')
          ENDIF
          IF (Zone(ZoneNum)%isControlled) THEN
            CALL ShowContinueError('...Zone is part of HVAC controlled system.')
          ELSE
            CALL ShowContinueError('...Zone is not part of HVAC controlled system.')
          ENDIF
          Zone(ZoneNum)%TempOutOfBoundsReported=.true.
        ENDIF
        CALL ShowRecurringSevereErrorAtEnd('Temperature (high) out of bounds for zone='//trim(Zone(ZoneNum)%Name)//  &
                       ' for surface='//TRIM(Surface(SurfNum)%Name),  &
                       Surface(SurfNum)%HighTempErrCount,ReportMaxOf=CheckTemperature,ReportMaxUnits='C',  &
                       ReportMinOf=CheckTemperature,ReportMinUnits='C')
      ELSE
        CALL ShowRecurringSevereErrorAtEnd('Temperature (high) out of bounds for zone='//trim(Zone(ZoneNum)%Name)//  &
                      ' for surface='//TRIM(Surface(SurfNum)%Name),  &
                       Surface(SurfNum)%HighTempErrCount,ReportMaxOf=CheckTemperature,ReportMaxUnits='C',  &
                       ReportMinOf=CheckTemperature,ReportMinUnits='C')
      ENDIF
    ENDIF
  ENDIF


  RETURN

END SUBROUTINE CheckFDSurfaceTempLimits

! *****************************************************************************

!     NOTICE
!
!     Copyright � 1996-2013 The Board of Trustees of the University of Illinois
!     and The Regents of the University of California through Ernest Orlando Lawrence
!     Berkeley National Laboratory.  All rights reserved.
!
!     Portions of the EnergyPlus software package have been developed and copyrighted
!     by other individuals, companies and institutions.  These portions have been
!     incorporated into the EnergyPlus software package under license.   For a complete
!     list of contributors, see "Notice" located in EnergyPlus.f90.
!
!     NOTICE: The U.S. Government is granted for itself and others acting on its
!     behalf a paid-up, nonexclusive, irrevocable, worldwide license in this data to
!     reproduce, prepare derivative works, and perform publicly and display publicly.
!     Beginning five (5) years after permission to assert copyright is granted,
!     subject to two possible five year renewals, the U.S. Government is granted for
!     itself and others acting on its behalf a paid-up, non-exclusive, irrevocable
!     worldwide license in this data to reproduce, prepare derivative works,
!     distribute copies to the public, perform publicly and display publicly, and to
!     permit others to do so.
!
!     TRADEMARKS: EnergyPlus is a trademark of the US Department of Energy.
!

End Module HeatBalFiniteDiffManager
