!=================================================================================================
!!
!> @brief       Solid and ocean tides modeling
!> @author      Vitali Braun (VB)
!> @author      Christopher Kebschull (CHK)
!!
!> @date        <ul>
!!                <li>VB:  16.07.2013 (initial design)    </li>
!!                <li>CHK: 13.11.2015 (updated to use with libslam)    </li>
!!                <li>VB:  15.05.2016 (updated to have only statements for all use statements)</li>
!!                <li>CHK: 04.01.2018 (Using Solarsystem_class)</li>
!!                <li>CHK: 05.01.2017 (created Tides_class)
!!              </ul>
!!
!> @details     This module contains parameters, subroutines and functions required for Earth's
!!              solid and ocean tides modeling, specifically in the context of numerical
!!              integration of a satellite trajectory.
!!
!> @copyright   Institute of Space Systems / TU Braunschweig
!!
!> @anchor      tides
!!
!> @todo        Find bug in Solid tides (comparing to 2-body trajectory -> discontinuity?!)
!> @todo        Ocean tide model implementation incorrect? No reference and Vallado seems to be wrong. Consider implementing a REAL IERS model
!!------------------------------------------------------------------------------------------------
module tides

  use slam_astro,             only: getEarthRadius, getEarthGravity, getEarthMass
  use slam_astro_conversions, only: getGeodeticLatLon, getRadiusLatLon
  use neptune_error_handling, only: E_SOLAR_SYSTEM_INIT, setNeptuneError
  use slam_error_handling,    only: isControlled, hasToReturn, hasFailed, FATAL, checkIn, checkOut
  use slam_math,              only: mag, pi, eps9, rad2deg, factorial
  use slam_reduction_class,   only: Reduction_type
  use solarsystem,            only: Solarsystem_class, ID_SUN, ID_MOON
  use slam_types,             only: dp

  implicit none

  private

    integer, parameter, public :: SOLID_TIDES = 1
    integer, parameter, public :: OCEAN_TIDES = 2

    type, public :: Tides_class

        logical, public :: tidesInitialized

    contains

        procedure :: initTides
        procedure :: getTidesAcceleration
        procedure :: setTidesInitFlag

    end type Tides_class

    ! Constructor
    interface Tides_class
        module procedure constructor
    end interface Tides_class

contains

    ! ====================================================================
    !!
    !>  @brief      Constructor that should be used to initialize variables.
    !!
    !!  @author     Christopher Kebschull
    !!  @date       <ul>
    !!                  <li>ChK: 05.01.2018 (initial implementation)</li>
    !!              </ul>
    !!  @anchor     constructor
    !!
    ! --------------------------------------------------------------------
    type(Tides_class) function constructor()
        constructor%tidesInitialized = .false.

    end function constructor

  !==============================================================================
  !
  !> @anchor      initTides
  !!
  !> @brief       Initialization of tides module
  !> @author      Vitali Braun
  !!
  !> @date        <ul>
  !!                <li> 16.07.2013 (initial design)    </li>
  !!              </ul>
  !!
  !!-----------------------------------------------------------------------------
  subroutine initTides(this)

    class(Tides_class)  :: this

    character(len=*), parameter  :: csubid = "initTides"

    if(isControlled()) then
      if(hasToReturn()) return
      call checkIn(csubid)
    end if

    if(this%tidesInitialized) then
      if(isControlled()) then
        call checkOut(csubid)
      end if
      return
    end if

    !** in geopotential module, activate function to provide computation parameters
    !call setTideSupport(.true.)

    !** done!
    if(isControlled()) then
      call checkOut(csubid)
    end if

    return

  end subroutine initTides

  !============================================================================
  !
  !> @anchor      getTidesAcceleration
  !!
  !> @brief       Providing accelerations due to ocean and solid Earth tides
  !> @author      Vitali Braun
  !!
  !> @param[in]   solarsystem_model   the solar system model
  !> @param[in]   reduction           reduction handler
  !> @param[in]   r_gcrf              position vector (gcrf)
  !> @param[in]   r_itrf              position vector (itrf)
  !> @param[in]   v_itrf              velocity vector (itrf)
  !> @param[in]   time_mjd            current MJD
  !> @param[in]   tidetype            1 = solid; 2 = ocean
  !> @param[out]  accel               acceleration vector in inertial frame
  !!
  !> @date        <ul>
  !!                <li> 16.07.2013 (initial design) </li>
  !!                <li> 11.02.2015 (changed to a stable method for Legendre functions recursion)</li>
  !!                <li> 12.02.2015 (corrected ocean tides and added solid earth pole tides)</li>
  !!              </ul>
  !!
  !> @details     This routine computes the acceleration due to Earth's ocean
  !!              and solid tides in an inertial frame (ECI).
  !!
  !!              \par Overview
  !!
  !!              <ol>
  !!                <li> Compute Legendre polynomials </li>
  !!                <li> Determine partial derivatives of disturbing potential </li>
  !!                <li> Compute acceleration in GCRF </li>
  !!                <li> Finish. </li>
  !!              </ol>
  !!
  !!------------------------------------------------------------------------------------------------
  subroutine getTidesAcceleration(                          &
                                        this,               &
                                        solarsystem_model,  &
                                        reduction,          &
                                        r_gcrf,             &  ! <-- DBL(3) radius vector in GCRF frame
                                        r_itrf,             &  ! <-- DBL(3) radius vector in ITRF frame
                                        v_itrf,             &  ! <-- DBL(3) velocity vector in ITRF frame
                                        time_mjd,           &  ! <-- DBL    current MJD
                                        tidetype,           &  ! <-- INT    tide type (1=solid, 2=ocean)
                                        accel               &  ! --> DBL(3) acceleration vector in inertial frame
                                      )

    use slam_io,                only: openFile, closeFile, SEQUENTIAL, IN_FORMATTED
    use slam_astro              
    use slam_math,              only: pi, deg2rad

    !** interface
    !----------------------------------------------
    class(Tides_class)                      :: this
    type(Solarsystem_class),intent(inout)   :: solarsystem_model
    type(Reduction_type),intent(inout)      :: reduction
    real(dp), dimension(3), intent(in)      :: r_itrf, r_gcrf
    real(dp), dimension(3), intent(in)      :: v_itrf
    real(dp),               intent(in)      :: time_mjd
    integer,                intent(in)      :: tidetype


    real(dp), dimension(3), intent(out) :: accel
    !----------------------------------------------

    character(len=*), parameter :: csubid = "getTidesAcceleration" ! subroutine id

    integer, parameter     :: SUN  = 1
    integer, parameter     :: MOON = 2
    integer                :: dm              ! coefficient in transformation between normalized and unnormalized quantities
    integer                :: i,l,m
    integer                :: lmax            ! maximum order of potential

    real(dp), dimension(2)         :: body_lat
    real(dp), dimension(2)         :: body_lon
    real(dp), dimension(0:6)       :: costerm, sinterm    ! cos(ml) and sin(ml)
    real(dp), dimension(2:6,0:6)   :: dC, dS      ! deviations in coefficients C and S due to tides
    real(dp), parameter            :: densWater = 1025.d9             ! water density in kg/km**3
    real(dp), dimension(2:3,0:3)   :: k = reshape((/0.29525d0, 0.093d0, &     ! nominal love numbers for degree and order
                                                    0.29470d0, 0.093d0, &
                                                    0.29801d0, 0.093d0, &
                                                    0.d0,      0.094d0/), (/2,4/))
    real(dp), dimension(2:6)       :: kld = (/-0.3075d0, -0.1950d0, & ! load deformation coefficients
                                              -0.1320d0, -0.1032d0, &
                                              -0.0892d0/)
    real(dp), dimension(0:2)       :: kp =(/-0.00087d0, -0.00079d0, -0.00057d0/)  ! nominal love numbers for correction of fourth degree term (k+nm)
    real(dp), dimension(2,0:6,0:6) :: lp          ! legendre polynomials for Sun and Moon
    real(dp), dimension(0:7,0:7)   :: lpsat       ! legendre polynomials for satellite
    real(dp), dimension(2)         :: mu          ! GM parameter of Sun and Moon
    real(dp), dimension(2)         :: pom, pomAvg ! polar motion variables xp,yp (current and running average) / rad
    real(dp), dimension(2)         :: rabs_body
    real(dp), dimension(3,2)       :: rBodyGCRF
    real(dp), dimension(3,2)       :: rBodyITRF

    real(dp) :: const         ! constant factor
    real(dp) :: dudlambda     ! dU/d(lambda)
    real(dp) :: dudphi        ! dU/d(phi_gc)
    real(dp) :: dudr          ! dU/d(rabs)
    real(dp) :: fac           ! factorial term for the conversion to unnormalized coefficients
    real(dp) :: insig1, insig2, insig3  ! cumulated sums
    real(dp) :: lambda              ! longitude
    real(dp) :: m1, m2              ! auxiliaries to account for pole tide
    real(dp) :: muEarth             ! Earth's gravity constant
    real(dp) :: oorabs              ! 1/rabs
    real(dp) :: oorabs2             ! 1/rabs2
    real(dp) :: oorabs3             ! 1/rabs3
    real(dp) :: oosqrt_r1r2         ! 1/sqrt(r1r2)
    real(dp) :: phi_gc              ! latitude geocentric
    real(dp) :: r1r2                ! radius(1)**2 + radius(2)**2
    real(dp) :: rabs                ! magnitude of radius vector
    real(dp) :: rabs2               ! squared radius magnitude
    real(dp) :: rabs3               ! cubed radius magnitude
    real(dp) :: rekm                ! Earth's radius in km
    real(dp) :: rrfac               ! temporary
    real(dp) :: sqrt_r1r2           ! sqrt(r1r2)
    real(dp) :: tanphi              ! tan(phi_gc)
    real(dp) :: temp, templ, temp2  ! temporary
    real(dp) :: temp_t1             ! temporary (used to support tides)
    real(dp) :: temp_t2             ! temporary (used to support tides)
    real(dp) :: temp_t3             ! temporary (used to support tides)
    real(dp) :: temp_t4             ! temporary (used to support tides)
    real(dp) :: temp_t5             ! temporary (used to support tides)

    integer                       :: ich, ios, temp_l, temp_m, ind
    character(len=255)            :: cbuf, Darw
    real(dp), dimension(5)        :: F_vect
    integer, dimension(1:17, 1:5) :: N_mat = reshape((/0, 0, 0, 0, -1, 0, -1, 0, -1, 0, 0, 0, -2, -1, 0, 0, 0, &
                                                       0, 0, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, &
                                                       0, 0, 0, -2, 0, -2, -2, -2, -2, -2, -2, 0, -2, -2, -2, -2, 0, &
                                                       0, 0, 0, 2, 0, 0, 0, -2, 0, 0, 2, 0, 0, 0, 0, 2, 0, &
                                                       1, 2, 0, -2, 0, -2, -2, -2, -2, -2, -2, 0, -2, -2, -2, -2, 0 /), (/17, 5/))
    real(dp) :: theta_g, temp_dCp, temp_dSp, temp_dCm, temp_dSm, arg, theta_f
    real :: temp_Doodson
    real(dp), dimension(1:17,2:6,0:6) :: dC_p, dS_p, dC_m, dS_m
    real(dp), parameter :: ge = 9.7803278d-3, gravConstant = 6.67408d-20
    logical, save :: first_call = .true.


    if(isControlled()) then
      if(hasToReturn()) return
      call checkIn(csubid)
    end if

    !=========================================================================
    !
    ! Get position of Sun and Moon in ITRF (latitude and longitude)
    !
    !-------------------------------------------------------------------------
    if(.not. solarsystem_model%getSolarSystemInitFlag()) then
      call setNeptuneError(E_SOLAR_SYSTEM_INIT, FATAL)
      return
    end if

    !** set maximum order
    select case(tidetype)
      case(SOLID_TIDES)
        lmax = 4
      case(OCEAN_TIDES)
        lmax = 6
    end select

    !** position in GCRF
    rBodyGCRF(:,SUN)  = solarsystem_model%getBodyPosition(time_mjd, ID_SUN)
    if(hasFailed()) return
    rBodyGCRF(:,MOON) = solarsystem_model%getBodyPosition(time_mjd, ID_MOON)
    if(hasFailed()) return

    rabs_body(SUN)  = mag(rBodyGCRF(:,SUN))
    rabs_body(MOON) = mag(rBodyGCRF(:,MOON))

    !** convert to ITRF
    call reduction%inertial2earthFixed(rBodyGCRF(:,SUN),  time_mjd, rBodyITRF(:,SUN))
    if(hasFailed()) return
    call reduction%inertial2earthFixed(rBodyGCRF(:,MOON), time_mjd, rBodyITRF(:,MOON))
    if(hasFailed()) return

    !** compute longitude and latitude
    call getGeodeticLatLon(rBodyITRF(:,SUN),  temp, body_lat(SUN),  body_lon(SUN))
    if(hasFailed()) return
    call getGeodeticLatLon(rBodyITRF(:,MOON), temp, body_lat(MOON), body_lon(MOON))
    if(hasFailed()) return


    !=========================================================================
    !
    ! Get GM parameters for Sun and Moon
    !
    !-------------------------------------------
    mu(SUN)  = solarsystem_model%getBodyGM(ID_SUN)
    if(hasFailed()) return
    mu(MOON) = solarsystem_model%getBodyGM(ID_MOON)
    if(hasFailed()) return


    !=========================================================================
    !
    ! Compute Legendre polynomials
    !
    !------------------------------------------
    do i = SUN, MOON

      lp(i,0,0) = 1.d0
      lp(i,0,1) = 0.d0
      lp(i,1,0) = sin(body_lat(i))
      lp(i,1,1) = cos(body_lat(i))

      !** determine legendre polynomials recursively
      do m = 0, lmax
        do l = max(2,m), lmax
          if(l == m) then
            lp(i,m,m) = (2*m-1)*lp(i,1,1)*lp(i,m-1,m-1)
          else if(l == m + 1) then
            lp(i,l,m) = (2*m+1)*lp(i,1,0)*lp(i,l-1,m)
          else
            lp(i,l,m) = ((2*l-1)*lp(i,1,0)*lp(i,l-1,m) - (l+m-1)*lp(i,l-2,m))/(l-m)
          end if
        end do
      end do
    end do ! Bodies

    !=========================================================================
    !
    ! Compute coefficients deviations for solid Earth tides
    !
    !----------------------------------------------------------------------

    dC = 0.d0
    dS = 0.d0

    muEarth = getEarthGravity()
    rekm    = getEarthRadius()

    if(tidetype == SOLID_TIDES) then

      do l = 2,lmax-1
        do m = 0,l
          if(m == 0) then
            dm = 1
          else
            dm = 2
          end if

          fac   = factorial(l-m)/factorial(l+m) ! consider transformation for unnormalized coefficients
          templ = k(l,m)*dm*fac/muEarth

          do i = SUN, MOON
            temp    = templ*mu(i)*(rekm/rabs_body(i))**(l+1.d0)*lp(i,l,m)
            dC(l,m) = dC(l,m) + temp*cos(m*body_lon(i))
            dS(l,m) = dS(l,m) + temp*sin(m*body_lon(i))
          end do
        end do
      end do

      !** correct changes in degree 4 coefficients due to degree 2 solid tides
      !----------------------------------------------------------------------------
      do m = 0,2
        if(m == 0) then
          dm = 1
        else
          dm = 2
        end if

        templ = kp(m)*dm*sqrt(1.8d0*(4-m)*(3-m)/(4.d0+m)/(3.d0+m))*factorial(2-m)/factorial(2+m)/muEarth

        do i = SUN, MOON
          temp    = templ*mu(i)*(rekm/rabs_body(i))**3*lp(i,2,m)
          dC(4,m) = dC(4,m) + temp*cos(m*body_lon(i))
          dS(4,m) = dS(4,m) + temp*sin(m*body_lon(i))
        end do
      end do

      !** pole tide correction to 2,1 terms (only if EOP selected and already initialized)
      !--------------------------------------------------------------------------------------
      if(reduction%getEopInitFlag()) then

        pom    = reduction%getPolarMotion(time_mjd)
        pomAvg = reduction%getPolarMotionAvg(time_mjd)

        m1 = pom(1) - pomAvg(1)
        m2 = pomAvg(2) - pom(2)

        dC(2,1) = dC(2,1) - 1.721d-9*(m1 - 0.0115*m2)
        dS(2,1) = dS(2,1) - 1.721d-9*(m2 + 0.0115*m1)

      end if

    !=========================================================================
    !
    ! Compute coefficients deviations for ocean tides
    !
    !----------------------------------------------------------------------
    else if(tidetype == OCEAN_TIDES) then

      dC = 0.d0
      dS = 0.d0

      const = 4*pi*gravConstant*densWater/ge

      !get Delaunay arguments in radians for the current time
      call getDelaunay_arg(time_mjd, F_vect)
      F_vect = F_vect*deg2rad

      !get Greenwich Mean Sidereal Time
      theta_g = getGMST(time_mjd)
      
      !read data only the first time (no need to repeat the operation at each call)
      if (first_call) then
        ich = openFile("../work/data/fes2004_Cnm-Snm.dat", SEQUENTIAL, IN_FORMATTED)
        do ind = 1, 54311
          read(ich, '(a)', iostat=ios) cbuf
          read(cbuf, *) temp_Doodson, Darw, temp_l, temp_m, temp_dCp, temp_dSp, temp_dCm, temp_dSm

          if (temp_l >= 2 .and. temp_l <= lmax) then
            !collect data for each tide constituent
            if (temp_Doodson >= 55.564 .and. temp_Doodson <= 55.566) then
              dC_p(1, temp_l, temp_m) = temp_dCp
              dS_p(1, temp_l, temp_m) = temp_dSp
              dC_m(1, temp_l, temp_m) = temp_dCm
              dS_m(1, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 55.574 .and. temp_Doodson <= 55.576) then
              dC_p(2, temp_l, temp_m) = temp_dCp
              dS_p(2, temp_l, temp_m) = temp_dSp
              dC_m(2, temp_l, temp_m) = temp_dCm
              dS_m(2, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 56.553 .and. temp_Doodson <= 56.555) then
              dC_p(3, temp_l, temp_m) = temp_dCp
              dS_p(3, temp_l, temp_m) = temp_dSp
              dC_m(3, temp_l, temp_m) = temp_dCm
              dS_m(3, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 57.554 .and. temp_Doodson <= 57.556) then
              dC_p(4, temp_l, temp_m) = temp_dCp
              dS_p(4, temp_l, temp_m) = temp_dSp
              dC_m(4, temp_l, temp_m) = temp_dCm
              dS_m(4, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 65.454 .and. temp_Doodson <= 65.456) then
              dC_p(5, temp_l, temp_m) = temp_dCp
              dS_p(5, temp_l, temp_m) = temp_dSp
              dC_m(5, temp_l, temp_m) = temp_dCm
              dS_m(5, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 75.554 .and. temp_Doodson <= 75.556) then
              dC_p(6, temp_l, temp_m) = temp_dCp
              dS_p(6, temp_l, temp_m) = temp_dSp
              dC_m(6, temp_l, temp_m) = temp_dCm
              dS_m(6, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 85.454 .and. temp_Doodson <= 85.456) then
              dC_p(7, temp_l, temp_m) = temp_dCp
              dS_p(7, temp_l, temp_m) = temp_dSp
              dC_m(7, temp_l, temp_m) = temp_dCm
              dS_m(7, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 93.554 .and. temp_Doodson <= 93.556) then
              dC_p(8, temp_l, temp_m) = temp_dCp
              dS_p(8, temp_l, temp_m) = temp_dSp
              dC_m(8, temp_l, temp_m) = temp_dCm
              dS_m(8, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 135.654 .and. temp_Doodson <= 135.656) then
              dC_p(9, temp_l, temp_m) = temp_dCp
              dS_p(9, temp_l, temp_m) = temp_dSp
              dC_m(9, temp_l, temp_m) = temp_dCm
              dS_m(9, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 145.554 .and. temp_Doodson <= 145.556) then
              dC_p(10, temp_l, temp_m) = temp_dCp
              dS_p(10, temp_l, temp_m) = temp_dSp
              dC_m(10, temp_l, temp_m) = temp_dCm
              dS_m(10, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 163.554 .and. temp_Doodson <= 163.556) then
              dC_p(11, temp_l, temp_m) = temp_dCp
              dS_p(11, temp_l, temp_m) = temp_dSp
              dC_m(11, temp_l, temp_m) = temp_dCm
              dS_m(11, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 165.554 .and. temp_Doodson <= 165.556) then
              dC_p(12, temp_l, temp_m) = temp_dCp
              dS_p(12, temp_l, temp_m) = temp_dSp
              dC_m(12, temp_l, temp_m) = temp_dCm
              dS_m(12, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 235.754 .and. temp_Doodson <= 235.756) then
              dC_p(13, temp_l, temp_m) = temp_dCp
              dS_p(13, temp_l, temp_m) = temp_dSp
              dC_m(13, temp_l, temp_m) = temp_dCm
              dS_m(13, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 245.654 .and. temp_Doodson <= 245.656) then
              dC_p(14, temp_l, temp_m) = temp_dCp
              dS_p(14, temp_l, temp_m) = temp_dSp
              dC_m(14, temp_l, temp_m) = temp_dCm
              dS_m(14, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 255.554 .and. temp_Doodson <= 255.556) then
              dC_p(15, temp_l, temp_m) = temp_dCp
              dS_p(15, temp_l, temp_m) = temp_dSp
              dC_m(15, temp_l, temp_m) = temp_dCm
              dS_m(15, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 273.554 .and. temp_Doodson <= 273.556) then
              dC_p(16, temp_l, temp_m) = temp_dCp
              dS_p(16, temp_l, temp_m) = temp_dSp
              dC_m(16, temp_l, temp_m) = temp_dCm
              dS_m(16, temp_l, temp_m) = temp_dSm
            else if (temp_Doodson >= 275.554 .and. temp_Doodson <= 275.556) then
              dC_p(17, temp_l, temp_m) = temp_dCp
              dS_p(17, temp_l, temp_m) = temp_dSp
              dC_m(17, temp_l, temp_m) = temp_dCm
              dS_m(17, temp_l, temp_m) = temp_dSm
            end if
          end if
        end do
        ich  = closeFile(ich)
        first_call = .false.
      end if

      do l = 2, lmax
        do m = 0, l
          if (m == 0) then
            dm = 1
          else
            dm = 2
          end if 
          fac = const*(1.d0 + kld(l))/(2.d0*l + 1.d0)*sqrt(factorial(l - m)*dm*(2.d0*l + 1.d0)/factorial(l + m))
          do i = 1, 17
            !compute the argument for each tide constituent
            arg = dot_product(N_mat(i, :), F_vect)
            theta_f = m*(theta_g + pi) - arg
            !get the produced gravity field corrections
            dC(l, m) = dC(l, m) + fac*((dC_p(i, l, m) + dC_m(i, l, m))*cos(theta_f) + (dS_p(i, l, m) + dS_m(i, l, m))*sin(theta_f))
            if (m == 0) then
              dS(l, m) = 0
            else
              dS(l, m) = dS(l, m) + fac*((dC_m(i, l, m) - dC_p(i, l, m))*sin(theta_f) + (dS_p(i, l, m) - dS_m(i, l, m))*cos(theta_f))
            end if
          end do
        end do
      end do

      !Ocean pole tide correction
      if(reduction%getEopInitFlag()) then

        pom    = reduction%getPolarMotion(time_mjd)
        pomAvg = reduction%getPolarMotionAvg(time_mjd)

        m1 = pom(1) - pomAvg(1)
        m2 = pomAvg(2) - pom(2)

        dC(2,1) = dC(2,1) - 2.1778d-10*(m1 - 0.01724*m2)*sqrt(5/3)
        dS(2,1) = dS(2,1) - 1.7232d-10*(m2 - 0.03365*m1)*sqrt(5/3)

      end if

     

!      const = densWater/muEarth*4.d0*pi*rekm**2.d0/getEarthMass()

!      do l = 2,lmax
!
!        templ = const/(2.d0*l + 1.d0)*(1.d0 + kld(l))

!        do m = 0,l
!          do i = SUN, MOON

!            temp = templ*mu(i)*(rekm/rabs_body(i))**(l+1.d0)*lp(i,l,m)

!            dC(l,m) = dC(l,m) + temp*cos(m*body_lon(i))
!            dS(l,m) = dS(l,m) + temp*sin(m*body_lon(i))

!          end do
!        end do
!      end do

      !** DEBUG
!     write(*,*) "---", time_mjd, "----"
!     do l = 2, lmax
!       do m=0,l
!         write(*,*) "l, m, dC, dS = ", l, m, dC(l,m), dS(l,m)
!         if(l==6 .and. m==5) then
!           write(*,*) "lp = ", lp(1,l,m), lp(2,l,m)
!         end if
!       end do
!     end do
!     write(*,*) "--------------"

    end if

    !===============================================================================================
    !
    ! Compute required quantities required for the accelerations (or take from geoopotential...)
    !
    !---------------------------------------------------------------------------------------------
    insig1 = 0.d0
    insig2 = 0.d0
    insig3 = 0.d0

    !** get radius, geocentric longitude and latitude
    call getRadiusLatLon(r_itrf, v_itrf, rabs, phi_gc, lambda)

    !** orbital radius
    rabs2        = rabs*rabs
    rabs3        = rabs2*rabs
    oorabs       = 1.d0/rabs
    oorabs2      = oorabs*oorabs
    oorabs3      = oorabs2*oorabs

    lpsat(0,0) = 1.d0
    lpsat(0,1) = 0.d0
    lpsat(1,0) = sin(phi_gc)
    lpsat(1,1) = cos(phi_gc)

    !** determine legendre polynomials recursively
    do m = 0, lmax

      do l = max(2,m), lmax

        if(l == m) then
          lpsat(m,m) = (2*m-1)*lpsat(1,1)*lpsat(m-1,m-1)
        else if(l == m + 1) then
          lpsat(l,m) = (2*m+1)*lpsat(1,0)*lpsat(l-1,m)
        else
          lpsat(l,m) = ((2*l-1)*lpsat(1,0)*lpsat(l-1,m) - (l+m-1)*lpsat(l-2,m))/(l-m)
        end if

      end do

    end do

    ! determine partial derivatives of the disturbing potential

    costerm(0) = 1.d0
    costerm(1) = cos(lambda)

    sinterm(0) = 0.d0
    sinterm(1) = sin(lambda)

    tanphi = tan(phi_gc)

    do l = 2,lmax

      !** recursive computation of sin(ml) and cos(ml)
      !--------------------------------------------------
      costerm(l) = 2.d0*costerm(1)*costerm(l-1)-costerm(l-2)
      sinterm(l) = 2.d0*costerm(1)*sinterm(l-1)-sinterm(l-2)

      ! determine pre-factor for expression inside the sigmas
      rrfac        = (rekm*oorabs)**l
      lpsat(l,l+1) = 0.d0

      do m = 0,l !MIN(l,maxord)

        temp_t1 = rrfac*(l+1)*lpsat(l,m)
        temp_t2 = rrfac*(lpsat(l,m+1) - (m * tanphi * lpsat(l,m)))
        temp_t3 = rrfac* m * lpsat(l,m)

        ! radial partial derivative of the potential
        insig1 = insig1 + temp_t1 * (dC(l,m)*costerm(m) + dS(l,m)*sinterm(m))

        ! phi (latitudal) derivative of the potential
        insig2 = insig2 + temp_t2 * (dC(l,m)*costerm(m) + dS(l,m)*sinterm(m))

        ! lambda (longitudal) derivative of the potential
        insig3 = insig3 + temp_t3 * (dS(l,m)*costerm(m) - dC(l,m)*sinterm(m))

      end do

    end do

    temp_t1 = -muEarth*oorabs3
    temp_t2 =  muEarth*oorabs

    ! compute the radial partial derivative of the potential
    dudr      = temp_t1 * insig1

    ! compute the latitutal partial derivative of the potential
    dudphi    =  temp_t2  * insig2

    ! compute the longitudal partial derivative of the potential
    dudlambda =  temp_t2  * insig3

    ! pre-compute terms which are used for the acceleration components
    r1r2        = r_gcrf(1)*r_gcrf(1) + r_gcrf(2)*r_gcrf(2)
    temp_t3     = 1.d0/r1r2
    sqrt_r1r2   = sqrt(r1r2)
    oosqrt_r1r2 = 1.d0/sqrt_r1r2
    temp_t4     = r_gcrf(3)*oorabs2*oosqrt_r1r2
    temp_t5     = oorabs2*sqrt_r1r2
    temp2       = dudlambda*temp_t3
    temp        = dudr - temp_t4*dudphi

    !==========================================================================
    !
    ! Finally, compute the non-spherical perturbative accelerations in the GCRF
    !
    !----------------------------------------------------------

    ! i-direction [km/s^2]
    accel(1) = temp * r_gcrf(1) - temp2 * r_gcrf(2)

    ! j-direction [km/s^2]
    accel(2) = temp * r_gcrf(2) + temp2 * r_gcrf(1)

    ! k-direction [km/s^2]
    accel(3) = dudr * r_gcrf(3) + temp_t5 * dudphi

    !write(*,*) "accel = ", accel
    !read(*,*)

    !** done!
    if(isControlled()) then
      call checkOut(csubid)
    end if

  end subroutine getTidesAcceleration

!=========================================================================
!
!> @anchor      setTidesInitFlag
!!
!> @brief       Set initialization flag to .false.
!> @author      Vitali Braun
!!
!> @date        <ul>
!!                <li> 16.07.2013 (initial design) </li>
!!              </ul>
!!
!!-----------------------------------------------------------------------
  subroutine setTidesInitFlag(this)

    class(Tides_class)  :: this
    this%tidesInitialized = .false.

  end subroutine setTidesInitFlag

  !=========================================================================
!
!> @anchor      getDelaunay_arg
!!
!> @brief       Compute the Delaunay arguments
!> @author      Andrea Turchi (ATU)
!!
!> @date        <ul>
!!                <li> 17.08.22 (initial design) </li>
!!              </ul>
!!
!!-----------------------------------------------------------------------
  subroutine getDelaunay_arg(time_mjd, F_vect)

    implicit none
    real(dp), intent(in)                :: time_mjd
    real(dp)                            :: l
    real(dp)                            :: l_prime
    real(dp)                            :: F
    real(dp)                            :: D
    real(dp)                            :: Omega
    real(dp), dimension(5), intent(out) :: F_vect

    l = 134.96 + 13.064993 * (time_mjd - 51544.5)
    l_prime = 357.53 + 0.985600 * (time_mjd - 51544.5)
    F = 93.27 + 13.229350 * (time_mjd - 51544.5)
    D = 297.85 + 12.190749 * (time_mjd - 51544.5)
    Omega = 125.04 - 0.052954 * (time_mjd - 51544.5)

    F_vect = (/l, l_prime, F, D, Omega/)

  end subroutine getDelaunay_arg

end module tides
