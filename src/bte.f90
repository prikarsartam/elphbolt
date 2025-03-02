! Copyright 2020 elphbolt contributors.
! This file is part of elphbolt <https://github.com/nakib/elphbolt>.
!
! elphbolt is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! elphbolt is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with elphbolt. If not, see <http://www.gnu.org/licenses/>.

module bte_module
  !! Module containing type and procedures related to the solution of the
  !! Boltzmann transport equation (BTE).

  use precision, only: r64, i64
  use params, only: qe, kB, hbar_eVps
  use misc, only: print_message, exit_with_message, write2file_rank2_real, &
       distribute_points, demux_state, binsearch, interpolate, demux_vector, mux_vector, &
       trace, subtitle, append2file_transport_tensor, write2file_response, &
       linspace, readfile_response, write2file_spectral_tensor, subtitle, timer, &
       twonorm, write2file_rank1_real, precompute_interpolation_corners_and_weights, &
       interpolate_using_precomputed, Jacobian, cross_product, qdist
  use numerics_module, only: numerics
  use crystal_module, only: crystal
  use nano_module, only: nanostructure
  use symmetry_module, only: symmetry
  use phonon_module, only: phonon
  use electron_module, only: electron
  use interactions, only: calculate_ph_rta_rates, read_transition_probs_e, &
       calculate_el_rta_rates, calculate_bound_scatt_rates, calculate_thinfilm_scatt_rates, &
       calculate_4ph_rta_rates, calculate_W3ph_OTF, calculate_Y_OTF, calculate_Xee_OTF
  use bz_sums, only: calculate_transport_coeff, calculate_spectral_transport_coeff, &
       calculate_cumulative_transport_coeff

  implicit none

  !external system, chdir
  
  private
  public bte

  type bte
     !! Data and procedures related to the BTE.

     real(r64), allocatable :: ph_rta_rates_iso_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ due to isotope scattering.
     real(r64), allocatable :: ph_rta_rates_subs_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ due to substitution scattering.
     real(r64), allocatable :: ph_rta_rates_bound_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ due to boundary scattering.
     real(r64), allocatable :: ph_rta_rates_thinfilm_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ due to thin-film scattering.
     real(r64), allocatable :: ph_rta_rates_3ph_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ due to 3-ph interactions.
     real(r64), allocatable :: ph_rta_rates_4ph_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ due to 4-ph interactions.
     real(r64), allocatable :: ph_rta_rates_phe_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ due to ph-e interactions.
     real(r64), allocatable :: ph_rta_rates_ibz(:,:)
     !! Phonon RTA scattering rates on the IBZ.
     real(r64), allocatable :: ph_field_term_T(:,:,:)
     !! Phonon field coupling term for gradT field on the FBZ.
     real(r64), allocatable :: ph_response_T(:,:,:)
     !! Phonon response function for gradT field on the FBZ.
     real(r64), allocatable :: ph_field_term_E(:,:,:)
     !! Phonon field coupling term for E field on the FBZ.
     real(r64), allocatable :: ph_response_E(:,:,:)
     !! Phonon response function for E field on the FBZ.
     
     real(r64), allocatable :: el_rta_rates_echimp_ibz(:,:)
     !! Electron RTA scattering rates on the IBZ due to charged impurity scattering.
     real(r64), allocatable :: el_rta_rates_bound_ibz(:,:)
     !! Electron RTA scattering rates on the IBZ due to boundary scattering.
     real(r64), allocatable :: el_rta_rates_eph_ibz(:,:)
     !! Electron RTA scattering rates on the IBZ due to e-ph interactions.
     real(r64), allocatable :: el_rta_rates_ee_ibz(:,:)
     !! Electron RTA scattering rates on the IBZ due to e-e interactions.
     real(r64), allocatable :: el_rta_rates_ibz(:,:)
     !! Electron RTA scattering rates on the IBZ.
     real(r64), allocatable :: el_field_term_T(:,:,:)
     !! Electron field coupling term for gradT field on the FBZ.
     real(r64), allocatable :: el_response_T(:,:,:)
     !! Electron response function for gradT field on the FBZ.
     real(r64), allocatable :: el_field_term_E(:,:,:)
     !! Electron field coupling term for E field on the FBZ.
     real(r64), allocatable :: el_response_E(:,:,:)
     !! Electron response function for E field on the FBZ.
   contains

     procedure :: solve_bte=>bte_driver, post_process
     
  end type bte

  type transport_coeffs
     !! Module level private data pack for all the transport coefficients.
     
     real(r64), allocatable :: ph_kappa(:,:,:), ph_alphabyT(:,:,:), &
          dummy(:,:,:), I_diff(:,:,:), I_drag(:,:,:), el_kappa0(:,:,:), el_alphabyT(:,:,:), &
          el_sigma(:, :,:), el_sigmaS(:, :, :), ph_drag_term_T(:,:,:), ph_drag_term_E(:,:,:)

     real(r64) :: ph_kappa_scalar, ph_kappa_scalar_old, ph_alphabyT_scalar, ph_alphabyT_scalar_old, &
          el_kappa0_scalar, el_kappa0_scalar_old, el_alphabyT_scalar, el_alphabyT_scalar_old, &
          el_sigma_scalar, el_sigma_scalar_old, el_sigmaS_scalar, el_sigmaS_scalar_old, KO_dev, lambda, &
          tot_alphabyT_scalar
     
   contains

     procedure :: initialize_ph=>allocate_ph_transport_coeffs, &
          initialize_el=>allocate_el_transport_coeffs
     
  end type transport_coeffs
    
contains

  subroutine allocate_ph_transport_coeffs(self, ph_numbands)
    !! Allocator of the phonon transport coefficients in the pack.
    !! TODO Generalize this to handle the case for multiple nanostructures.
    
    class(transport_coeffs), intent(inout) :: self
    integer(i64), intent(in) :: ph_numbands

    allocate(self%ph_kappa(ph_numbands, 3, 3), self%ph_alphabyT(ph_numbands, 3, 3), &
         self%dummy(ph_numbands, 3, 3))
  end subroutine allocate_ph_transport_coeffs

  subroutine allocate_el_transport_coeffs(self, el_numbands)
    !! Allocator of the electron transport coefficients in the pack.
    !! TODO Generalize this to handle the case for multiple nanostructures.
    
    class(transport_coeffs), intent(inout) :: self
    integer(i64), intent(in) :: el_numbands

    allocate(self%el_sigma(el_numbands, 3, 3), self%el_sigmaS(el_numbands, 3, 3), &
         self%el_alphabyT(el_numbands, 3, 3), self%el_kappa0(el_numbands, 3, 3))
  end subroutine allocate_el_transport_coeffs
  
  subroutine bte_driver(self, num, crys, sym, ph, el)
    !! Subroutine to orchestrate the BTE calculations.
    !!
    !! self BTE object
    !! num Numerics object
    !! crys Crystal object
    !! sym Symmertry object
    !! ph Phonon object
    !! el Electron object
    
    class(bte), intent(inout) :: self
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    type(symmetry), intent(in) :: sym
    type(phonon), intent(in) :: ph
    type(electron), intent(in), optional :: el

    !Local variables
    character(1024) :: tag, Tdir

    call subtitle("Calculating transport (bulk)...")

    call print_message("Only the trace-averaged transport coefficients are printed below:")

    !Create output folder tagged by temperature and create it
    write(tag, "(E9.3)") crys%T
    Tdir = trim(adjustl(num%cwd))//'/T'//trim(adjustl(tag))
    if(this_image() == 1) then
       call system('mkdir -p '//trim(adjustl(Tdir)))
    end if
    sync all
    
    !Phonon RTA
    if(.not. num%onlyebte) &
         call dragless_phbte_RTA(Tdir, self, num, crys, sym, ph, el)

    !Electron RTA
    if(.not. num%onlyphbte) &
         call dragless_ebte_RTA(Tdir, self, num, crys, sym, el, ph)
    
    !Dragful electron-phonon BTEs
    if(num%drag) &
         call dragfull_ephbtes(Tdir, self, num, crys, sym, ph, el)

    !Dragless full phonon BTE
    if(num%onlyphbte .or. num%drag) &
         call dragless_phbte_full(Tdir, self, num, crys, sym, ph, el)

    !Dragless full electron BTE
    if(num%onlyebte .or. num%drag) &
         call dragless_ebte_full(Tdir, self, num, crys, sym, el)
  end subroutine bte_driver
  
  subroutine dragless_ebte_RTA(Tdir, self, num, crys, sym, el, ph)
    !! Dragless electron BTE calculator in the relaxation time approximation.
    !! It is impure as it mutates the electron sector of the bte data type and
    !! writes to disk. It should be kept private to this data type unless made safer.

    class(bte), intent(inout) :: self !Mutation alert!
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    type(symmetry), intent(in) :: sym
    type(phonon), intent(in) :: ph
    type(electron), intent(in) :: el
    character(*), intent(in) :: Tdir

    !Locals
    real(r64) :: el_kappa0_scalar, el_kappa0_scalar_old, el_alphabyT_scalar, el_alphabyT_scalar_old, &
         el_sigma_scalar, el_sigma_scalar_old, el_sigmaS_scalar, el_sigmaS_scalar_old
    type(timer) :: t
    integer(i64) :: ik
    type(transport_coeffs) :: trans

    call trans%initialize_el(el%numbands)
    
    call t%start_timer('RTA e BTE')

    !Calculate RTA scattering rates
    ! e-ph and e-impurity
    call calculate_el_rta_rates(self%el_rta_rates_eph_ibz, self%el_rta_rates_echimp_ibz, &
         self%el_rta_rates_ee_ibz, num, crys, el)

    ! e-boundary
    call calculate_bound_scatt_rates(el%prefix, num%elbound, crys%bound_length, &
         el%vels, el%indexlist_irred, self%el_rta_rates_bound_ibz)

    !Allocate total RTA scattering rates
    allocate(self%el_rta_rates_ibz(el%nwv_irred, el%numbands))

    !Matthiessen's rule
    self%el_rta_rates_ibz = self%el_rta_rates_eph_ibz + self%el_rta_rates_echimp_ibz + &
         self%el_rta_rates_ee_ibz + self%el_rta_rates_bound_ibz

    !gradT field:
    ! Calculate field term (gradT=>I0)
    call calculate_field_term('el', 'T', el%nequiv, el%ibz2fbz_map, &
         crys%T, el%chempot, el%ens, el%vels, self%el_rta_rates_ibz, &
         self%el_field_term_T, el%indexlist)

    ! Symmetrize field term
    do ik = 1, el%nwv
       self%el_field_term_T(ik,:,:) = &
            transpose(matmul(el%symmetrizers(:, :, ik), transpose(self%el_field_term_T(ik, :, :))))
    end do

    ! RTA solution of BTE
    allocate(self%el_response_T(el%nwv, el%numbands, 3))
    self%el_response_T = self%el_field_term_T

    ! Calculate transport coefficient
    call calculate_transport_coeff('el', 'T', crys%T, el%spindeg, el%chempot, el%ens, &
         el%vels, crys%volume, el%wvmesh, self%el_response_T, sym, trans%el_kappa0, trans%el_sigmaS)

    !E field:
    ! Calculate field term (E=>J0)
    call calculate_field_term('el', 'E', el%nequiv, el%ibz2fbz_map, &
         crys%T, el%chempot, el%ens, el%vels, self%el_rta_rates_ibz, &
         self%el_field_term_E, el%indexlist)

    ! Symmetrize field term
    do ik = 1, el%nwv
       self%el_field_term_E(ik, :, :) = &
            transpose(matmul(el%symmetrizers(:, :, ik), transpose(self%el_field_term_E(ik, :, :))))
    end do

    ! RTA solution of BTE
    allocate(self%el_response_E(el%nwv, el%numbands, 3))
    self%el_response_E = self%el_field_term_E

    ! Calculate transport coefficient
    call calculate_transport_coeff('el', 'E', crys%T, el%spindeg, el%chempot, el%ens, el%vels, &
         crys%volume, el%wvmesh, self%el_response_E, sym, trans%el_alphabyT, trans%el_sigma)
    trans%el_alphabyT = trans%el_alphabyT/crys%T
    !--!

    !Change to data output directory
    call chdir(trim(adjustl(Tdir)))

    !Write e-ph RTA scattering rates to file
    call write2file_rank2_real('el.W_rta_eph', self%el_rta_rates_eph_ibz)

    !Write e-e RTA scattering rates to file
    call write2file_rank2_real('el.W_rta_ee', self%el_rta_rates_ee_ibz)

    !Write e-chimp RTA scattering rates to file
    call write2file_rank2_real('el.W_rta_echimp', self%el_rta_rates_echimp_ibz)

    !Change back to cwd
    call chdir(trim(adjustl(num%cwd)))

    !Calculate and print transport scalars
    !gradT:
    el_kappa0_scalar = trace(sum(trans%el_kappa0, dim = 1))/crys%dim
    el_sigmaS_scalar = trace(sum(trans%el_sigmaS, dim = 1))/crys%dim

    !E:
    el_sigma_scalar = trace(sum(trans%el_sigma, dim = 1))/crys%dim
    el_alphabyT_scalar = trace(sum(trans%el_alphabyT, dim = 1))/crys%dim

    !if(.not. num%drag .and. this_image() == 1) then
    if(this_image() == 1) then
       call print_message("RTA solution:")
       call print_message("-------------")
       write(*,*) "iter    k0_el[W/m/K]        sigmaS[A/m/K]", &
            "         sigma[1/Ohm/m]      alpha_el/T[A/m/K]"
       write(*,"(I3, A, 1E16.8, A, 1E16.8, A, 1E16.8, A, 1E16.8)") 0, &
            "    ", el_kappa0_scalar, "     ", el_sigmaS_scalar, &
            "     ", el_sigma_scalar, "     ", el_alphabyT_scalar
    end if

    el_kappa0_scalar_old = el_kappa0_scalar
    el_sigmaS_scalar_old = el_sigmaS_scalar
    el_sigma_scalar_old = el_sigma_scalar 
    el_alphabyT_scalar_old = el_alphabyT_scalar

    ! Append RTA coefficients in no-drag files
    ! Change to data output directory
    call chdir(trim(adjustl(Tdir)))
    call append2file_transport_tensor('nodrag_el_sigmaS_', 0, trans%el_sigmaS, el%bandlist)
    call append2file_transport_tensor('nodrag_el_sigma_', 0, trans%el_sigma, el%bandlist)
    call append2file_transport_tensor('nodrag_el_alphabyT_', 0, trans%el_alphabyT, el%bandlist)
    call append2file_transport_tensor('nodrag_el_kappa0_', 0, trans%el_kappa0, el%bandlist)

    ! Print RTA band/branch resolved response functions
    call write2file_response('RTA_I0_', self%el_response_T, el%bandlist) !gradT, el
    call write2file_response('RTA_J0_', self%el_response_E, el%bandlist) !E, el

    ! Change back to cwd
    call chdir(trim(adjustl(num%cwd)))

    call t%end_timer('RTA e BTE')

    sync all
  end subroutine dragless_ebte_RTA

  subroutine dragless_ebte_full(Tdir, self, num, crys, sym, el)
    !! Dragless full electron BTE calculator.
    !! It is impure as it mutates the electron sector of the bte data type and
    !! writes to disk. It should be kept private to this data type unless made safer.

    class(bte), intent(inout) :: self !Mutation alert!
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    type(symmetry), intent(in) :: sym
    type(electron), intent(in) :: el
    character(*), intent(in) :: Tdir

    !Locals
    real(r64) :: el_kappa0_scalar, el_kappa0_scalar_old, el_alphabyT_scalar, el_alphabyT_scalar_old, &
         el_sigma_scalar, el_sigma_scalar_old, el_sigmaS_scalar, el_sigmaS_scalar_old
    type(timer) :: t
    integer :: it_el, icart
    type(transport_coeffs) :: trans

    call trans%initialize_el(el%numbands)
    
    call t%start_timer('Iterative dragless e BTE')

    call print_message("Dragless electron transport:")
    call print_message("-----------------------------")

    !Restart with RTA solution
    self%el_response_T = self%el_field_term_T
    self%el_response_E = self%el_field_term_E

    if(this_image() == 1) then
       write(*,*) "iter    k0_el[W/m/K]        sigmaS[A/m/K]", &
            "         sigma[1/Ohm/m]      alpha_el/T[A/m/K]"
    end if

    do it_el = 1, num%maxiter
       !E field:
       call iterate_bte_el(num, el, crys, &
            self%el_rta_rates_ibz, self%el_field_term_E, self%el_response_E)

       !Calculate electron transport coefficients
       call calculate_transport_coeff('el', 'E', crys%T, el%spindeg, el%chempot, &
            el%ens, el%vels, crys%volume, el%wvmesh, self%el_response_E, sym, &
            trans%el_alphabyT, trans%el_sigma, Bfield = num%Bfield)
       trans%el_alphabyT = trans%el_alphabyT/crys%T

       !delT field:
       call iterate_bte_el(num, el, crys, &
            self%el_rta_rates_ibz, self%el_field_term_T, self%el_response_T)
       !Enforce Kelvin-Onsager relation
       do icart = 1, 3
          self%el_response_T(:,:,icart) = (el%ens(:,:) - el%chempot)/qe/crys%T*&
               self%el_response_E(:,:,icart)
       end do

       call calculate_transport_coeff('el', 'T', crys%T, el%spindeg, el%chempot, &
            el%ens, el%vels, crys%volume, el%wvmesh, self%el_response_T, sym, &
            trans%el_kappa0, trans%el_sigmaS, Bfield = num%Bfield)

       !Calculate and print electron transport scalars
       el_kappa0_scalar = trace(sum(trans%el_kappa0, dim = 1))/crys%dim
       el_sigmaS_scalar = trace(sum(trans%el_sigmaS, dim = 1))/crys%dim
       el_sigma_scalar = trace(sum(trans%el_sigma, dim = 1))/crys%dim
       el_alphabyT_scalar = trace(sum(trans%el_alphabyT, dim = 1))/crys%dim
       if(this_image() == 1) then
          write(*,"(I3, A, 1E16.8, A, 1E16.8, A, 1E16.8, A, 1E16.8)") it_el, &
               "    ", el_kappa0_scalar, "     ", el_sigmaS_scalar, &
               "     ", el_sigma_scalar, "     ", el_alphabyT_scalar
       end if

       !Print out band resolved transport coefficients
       ! Change to data output directory
       call chdir(trim(adjustl(Tdir)))
       call append2file_transport_tensor('nodrag_el_sigmaS_', it_el, trans%el_sigmaS, el%bandlist)
       call append2file_transport_tensor('nodrag_el_sigma_', it_el, trans%el_sigma, el%bandlist)
       call append2file_transport_tensor('nodrag_el_alphabyT_', it_el, trans%el_alphabyT, el%bandlist)
       call append2file_transport_tensor('nodrag_el_kappa0_', it_el, trans%el_kappa0, el%bandlist)
       ! Change back to cwd
       call chdir(trim(adjustl(num%cwd)))

       !Check convergence
       if(converged(el_kappa0_scalar_old, el_kappa0_scalar, num%conv_thres) .and. &
            converged(el_sigmaS_scalar_old, el_sigmaS_scalar, num%conv_thres) .and. &
            converged(el_sigma_scalar_old, el_sigma_scalar, num%conv_thres) .and. &
            converged(el_alphabyT_scalar_old, el_alphabyT_scalar, num%conv_thres)) then

          !Print converged band resolved response functions
          ! Change to data output directory
          call chdir(trim(adjustl(Tdir)))
          call write2file_response('nodrag_I0_', self%el_response_T, el%bandlist) !gradT, el
          call write2file_response('nodrag_J0_', self%el_response_E, el%bandlist) !E, el
          ! Change back to cwd
          call chdir(trim(adjustl(num%cwd)))

          exit
       else
          el_kappa0_scalar_old = el_kappa0_scalar
          el_sigmaS_scalar_old = el_sigmaS_scalar
          el_sigma_scalar_old = el_sigma_scalar
          el_alphabyT_scalar_old = el_alphabyT_scalar
       end if
    end do

    call t%end_timer('Iterative dragless e BTE')

    sync all
  end subroutine dragless_ebte_full

  subroutine dragless_phbte_RTA(Tdir, self, num, crys, sym, ph, el)
    !! Dragless phonon BTE calculator in the relaxation time approximation.
    !! It is impure as it mutates the phonon sector of the bte data type and
    !! writes to disk. It should be kept private to this data type unless made safer.

    class(bte), intent(inout) :: self !Mutation alert!
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    type(symmetry), intent(in) :: sym
    type(phonon), intent(in) :: ph
    type(electron), intent(in) :: el
    character(*), intent(in) :: Tdir

    !Locals
    real(r64) :: ph_kappa_scalar, ph_kappa_scalar_old, ph_alphabyT_scalar, ph_alphabyT_scalar_old
    type(timer) :: t
    integer(i64) :: iq
    type(transport_coeffs) :: trans

    call trans%initialize_ph(ph%numbands)
    
    call t%start_timer('RTA ph BTE')

    !Allocate total RTA scattering rates
    allocate(self%ph_rta_rates_ibz(ph%nwv_irred, ph%numbands))

    !Calculate RTA scattering rates

    ! 3-phonon and, optionally, phonon-electron 
    if(num%phe) then
       call calculate_ph_rta_rates(self%ph_rta_rates_3ph_ibz, self%ph_rta_rates_phe_ibz, num, crys, ph, el)
    else
       call calculate_ph_rta_rates(self%ph_rta_rates_3ph_ibz, self%ph_rta_rates_phe_ibz, num, crys, ph)
    end if

    ! 4-ph scattering rates
    call calculate_4ph_rta_rates(self%ph_rta_rates_4ph_ibz, num, crys, ph)

    ! phonon-boundary
    call calculate_bound_scatt_rates(ph%prefix, num%phbound, crys%bound_length, &
         ph%vels, ph%indexlist_irred, self%ph_rta_rates_bound_ibz)

    !Matthiessen's rule without thin-film
    self%ph_rta_rates_ibz = self%ph_rta_rates_3ph_ibz + self%ph_rta_rates_phe_ibz + &
         self%ph_rta_rates_iso_ibz + self%ph_rta_rates_subs_ibz + &
         self%ph_rta_rates_bound_ibz + self%ph_rta_rates_4ph_ibz

    ! phonon-thin-film
    call calculate_thinfilm_scatt_rates(ph%prefix, num%phthinfilm, num%phthinfilm_ballistic, &
         crys%specfac, crys%thinfilm_height, crys%thinfilm_normal, &
         ph%vels, ph%indexlist_irred, self%ph_rta_rates_ibz, self%ph_rta_rates_thinfilm_ibz)

    !Matthiessen's rule with thin-film
    self%ph_rta_rates_ibz = self%ph_rta_rates_ibz + self%ph_rta_rates_thinfilm_ibz

    !gradT field:
    ! Calculate field term (gradT=>F0)
    call calculate_field_term('ph', 'T', ph%nequiv, ph%ibz2fbz_map, &
         crys%T, 0.0_r64, ph%ens, ph%vels, self%ph_rta_rates_ibz, self%ph_field_term_T)

    ! Symmetrize field term
    do iq = 1, ph%nwv
       self%ph_field_term_T(iq,:,:)=transpose(&
            matmul(ph%symmetrizers(:,:,iq),transpose(self%ph_field_term_T(iq,:,:))))
    end do

    ! RTA solution of BTE
    allocate(self%ph_response_T(ph%nwv, ph%numbands, 3))
    self%ph_response_T = self%ph_field_term_T

    ! Calculate transport coefficient
    call calculate_transport_coeff('ph', 'T', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
         crys%volume, ph%wvmesh, self%ph_response_T, sym, trans%ph_kappa, trans%dummy)
    !---------------------------------------------------------------------------------!

    !E field:
    ! Calculate field term (E=>G0)
    call calculate_field_term('ph', 'E', ph%nequiv, ph%ibz2fbz_map, &
         crys%T, 0.0_r64, ph%ens, ph%vels, self%ph_rta_rates_ibz, self%ph_field_term_E)

    ! RTA solution of BTE
    allocate(self%ph_response_E(ph%nwv, ph%numbands, 3))
    self%ph_response_E = self%ph_field_term_E

    ! Calculate transport coefficient
    call calculate_transport_coeff('ph', 'E', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
         crys%volume, ph%wvmesh, self%ph_response_E, sym, trans%ph_alphabyT, trans%dummy)
    trans%ph_alphabyT = trans%ph_alphabyT/crys%T
    !---------------------------------------------------------------------------------!

    !Change to data output directory
    call chdir(trim(adjustl(Tdir)))

    !Write T-dependent RTA scattering rates to file
    call write2file_rank2_real('ph.W_rta_3ph', self%ph_rta_rates_3ph_ibz)
    call write2file_rank2_real('ph.W_rta_4ph', self%ph_rta_rates_4ph_ibz)
    call write2file_rank2_real('ph.W_rta_phe', self%ph_rta_rates_phe_ibz)
    call write2file_rank2_real('ph.W_rta', self%ph_rta_rates_ibz)

    !Change back to cwd
    call chdir(trim(adjustl(num%cwd)))

    !Calculate and print transport scalars
    !gradT:
    ph_kappa_scalar = trace(sum(trans%ph_kappa, dim = 1))/crys%dim
    !E:
    ph_alphabyT_scalar = trace(sum(trans%ph_alphabyT, dim = 1))/crys%dim

    !if(.not. num%drag .and. this_image() == 1) then
    if(this_image() == 1) then
    call print_message("RTA solution:")
    call print_message("-------------")
       write(*,*) "iter    k_ph[W/m/K]"
       write(*,"(I3, A, 1E16.8)") 0, "    ", ph_kappa_scalar
    end if

    ph_kappa_scalar_old = ph_kappa_scalar
    ph_alphabyT_scalar_old = ph_alphabyT_scalar

    ! Append RTA coefficients in no-drag files
    ! Change to data output directory
    call chdir(trim(adjustl(Tdir)))
    call append2file_transport_tensor('nodrag_ph_kappa_', 0, trans%ph_kappa)

    ! Print RTA band/branch resolved response functions
    call write2file_response('RTA_F0_', self%ph_response_T) !gradT, ph

    ! Change back to cwd
    call chdir(trim(adjustl(num%cwd)))

    call t%end_timer('RTA ph BTE')

    sync all
  end subroutine dragless_phbte_RTA

  subroutine dragless_phbte_full(Tdir, self, num, crys, sym, ph, el)
    !! Dragless phonon BTE calculator in the relaxation time approximation.
    !! It is impure as it mutates the phonon sector of the bte data type and
    !! writes to disk. It should be kept private to this data type unless made safer.

    class(bte), intent(inout) :: self !Mutation alert!
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    type(symmetry), intent(in) :: sym
    type(phonon), intent(in) :: ph
    type(electron), intent(in) :: el
    character(*), intent(in) :: Tdir

    !Locals
    real(r64) :: ph_kappa_scalar, ph_kappa_scalar_old, ph_alphabyT_scalar, ph_alphabyT_scalar_old
    type(timer) :: t
    integer :: it_ph
    type(transport_coeffs) :: trans

    call trans%initialize_ph(ph%numbands)
    
    call t%start_timer('Iterative dragless ph BTE')

    call print_message("Dragless phonon transport:")
    call print_message("---------------------------")

    !Restart with RTA solution
    self%ph_response_T = self%ph_field_term_T

    if(this_image() == 1) then
       write(*,*) "iter    k_ph[W/m/K]"
    end if

    do it_ph = 1, num%maxiter
       call iterate_bte_ph(crys%T, num, crys, ph, el, self%ph_rta_rates_ibz, &
            self%ph_field_term_T, self%ph_response_T)

       !Calculate phonon transport coefficients
       call calculate_transport_coeff('ph', 'T', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
            crys%volume, ph%wvmesh, self%ph_response_T, sym, trans%ph_kappa, trans%dummy)

       !Calculate and print phonon transport scalar
       ph_kappa_scalar = trace(sum(trans%ph_kappa, dim = 1))/crys%dim
       if(this_image() == 1) then
          write(*,"(I3, A, 1E16.8)") it_ph, "    ", ph_kappa_scalar
       end if

       !Print out branch resolved transport coefficients
       ! Change to data output directory
       call chdir(trim(adjustl(Tdir)))
       call append2file_transport_tensor('nodrag_ph_kappa_', it_ph, trans%ph_kappa)
       ! Change back to cwd
       call chdir(trim(adjustl(num%cwd)))

       if(converged(ph_kappa_scalar_old, ph_kappa_scalar, num%conv_thres)) then
          !Print converged branch resolved response functions
          ! Change to data output directory
          call chdir(trim(adjustl(Tdir)))
          call write2file_response('nodrag_F0_', self%ph_response_T) !gradT, ph
          ! Change back to cwd
          call chdir(trim(adjustl(num%cwd)))

          exit
       else
          ph_kappa_scalar_old = ph_kappa_scalar
       end if
    end do

    call t%end_timer('Iterative dragless ph BTE')

    sync all
  end subroutine dragless_phbte_full

  subroutine dragfull_ephbtes(Tdir, self, num, crys, sym, ph, el)
    !! Dragful electron-phonon BTEs calculator.
    !! It is impure as it mutates the the bte data type and
    !! writes to disk. It should be kept private to this data type unless made safer.

    class(bte), intent(inout) :: self !Mutation alert!
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    type(symmetry), intent(in) :: sym
    type(phonon), intent(in) :: ph
    type(electron), intent(in) :: el
    character(*), intent(in) :: Tdir

    !Locals
    real(r64) :: ph_kappa_scalar, ph_kappa_scalar_old, ph_alphabyT_scalar, ph_alphabyT_scalar_old, &
         el_kappa0_scalar, el_kappa0_scalar_old, el_alphabyT_scalar, el_alphabyT_scalar_old, &
         el_sigma_scalar, el_sigma_scalar_old, el_sigmaS_scalar, el_sigmaS_scalar_old, KO_dev, lambda, &
         tot_alphabyT_scalar
    real(r64), allocatable :: I_diff(:,:,:), I_drag(:,:,:), &
         ph_drag_term_T(:,:,:), ph_drag_term_E(:,:,:), widc(:,:)
    integer(i64), allocatable :: idc(:,:) , ksint(:,:)
    integer :: it_ph, it_el, icart
    integer(i64) :: ik
    character(:), allocatable :: tableheader
    type(timer) :: t
    type(transport_coeffs) :: trans

    call trans%initialize_el(el%numbands)
    call trans%initialize_ph(ph%numbands)
    
    call t%start_timer('Coupled e-ph BTEs')
    
    allocate(widc(product(el%wvmesh),6), idc(product(el%wvmesh),9), &
         ksint(product(el%wvmesh),3))
    do ik = 1, size(ksint,1)
       call demux_vector(ik, ksint(ik,:), el%wvmesh, 0_i64)
    end do
    call precompute_interpolation_corners_and_weights(ph%wvmesh,  &
         el%mesh_ref_array, ksint, idc, widc)

    tot_alphabyT_scalar = el_alphabyT_scalar + ph_alphabyT_scalar
    KO_dev = 100.0_r64*abs(&
         (el_sigmaS_scalar - tot_alphabyT_scalar)/tot_alphabyT_scalar)

    ! We need to compute the RTA values again (that is relatively cheap)
    call calculate_transport_coeff('ph', 'T', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
         crys%volume, ph%wvmesh, self%ph_response_T, sym, trans%ph_kappa, trans%dummy)
    call calculate_transport_coeff('ph', 'E', crys%T, 1_i64, 0.0_r64, ph%ens,  ph%vels, &
         crys%volume, ph%wvmesh, self%ph_response_E, sym, trans%ph_alphabyT, trans%dummy)
   call calculate_transport_coeff('el', 'T', crys%T, el%spindeg, el%chempot, el%ens, &
         el%vels, crys%volume, el%wvmesh, self%el_response_T, sym, trans%el_kappa0, trans%el_sigmaS)
    call calculate_transport_coeff('el', 'E', crys%T, el%spindeg, el%chempot, el%ens, el%vels, &
         crys%volume, el%wvmesh, self%el_response_E, sym, trans%el_alphabyT, trans%el_sigma)
    trans%el_alphabyT = trans%el_alphabyT/crys%T
    trans%ph_alphabyT = trans%ph_alphabyT/crys%T
    
    ! Change to data output directory
    call chdir(trim(adjustl(Tdir)))
    call append2file_transport_tensor('drag_ph_kappa_', 0, trans%ph_kappa)
    call append2file_transport_tensor('drag_ph_alphabyT_', 0, trans%ph_alphabyT)
    call append2file_transport_tensor('drag_el_sigmaS_', 0, trans%el_sigmaS, el%bandlist)
    call append2file_transport_tensor('drag_el_sigma_', 0, trans%el_sigma, el%bandlist)
    call append2file_transport_tensor('drag_el_alphabyT_', 0, trans%el_alphabyT, el%bandlist)
    call append2file_transport_tensor('drag_el_kappa0_', 0, trans%el_kappa0, el%bandlist)
    ! Change back to cwd
    call chdir(trim(adjustl(num%cwd)))

    call print_message("Coupled electron-phonon transport:")
    call print_message("----------------------------------")

    if(this_image() == 1) then
       tableheader = "iter     k0_el[W/m/K]         sigmaS[A/m/K]         k_ph[W/m/K]"&
            //"         sigma[1/Ohm/m]         alpha_el/T[A/m/K]         alpha_ph/T[A/m/K]"&
            //"         KO dev.[%]"
       write(*,*) trim(tableheader)
    end if

    !These will be needed below
    allocate(I_drag(el%nwv, el%numbands, 3), I_diff(el%nwv, el%numbands, 3), &
         ph_drag_term_T(el%nwv, el%numbands, 3), ph_drag_term_E(el%nwv, el%numbands, 3))

    !Start iterator
    do it_ph = 1, num%maxiter       
       !Scheme: for each step of phonon response, fully iterate the electron response.

       !Iterate phonon response once          
       call iterate_bte_ph(crys%T, num, crys, ph, el, self%ph_rta_rates_ibz, &
            self%ph_field_term_T, self%ph_response_T, self%el_response_T)
       call iterate_bte_ph(crys%T, num, crys, ph, el, self%ph_rta_rates_ibz, &
            self%ph_field_term_E, self%ph_response_E, self%el_response_E)

       !Calculate phonon transport coefficients
       call calculate_transport_coeff('ph', 'T', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
            crys%volume, ph%wvmesh, self%ph_response_T, sym, trans%ph_kappa, trans%dummy)
       call calculate_transport_coeff('ph', 'E', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
            crys%volume, ph%wvmesh, self%ph_response_E, sym, trans%ph_alphabyT, trans%dummy)
       trans%ph_alphabyT = trans%ph_alphabyT/crys%T

       !Calculate phonon drag term for the current phBTE iteration.
       call calculate_phonon_drag(num, el, ph, idc, widc, sym, self%el_rta_rates_ibz, &
            self%ph_response_E, ph_drag_term_E)
       call calculate_phonon_drag(num, el, ph, idc, widc, sym, self%el_rta_rates_ibz, &
            self%ph_response_T, ph_drag_term_T)

       !Iterate electron response all the way
       do it_el = 1, num%maxiter
          !E field:
          call iterate_bte_el(num, el, crys, &
               self%el_rta_rates_ibz, self%el_field_term_E, self%el_response_E, ph_drag_term_E)

          !Calculate electron transport coefficients
          call calculate_transport_coeff('el', 'E', crys%T, el%spindeg, el%chempot, &
               el%ens, el%vels, crys%volume, el%wvmesh, self%el_response_E, sym, &
               trans%el_alphabyT, trans%el_sigma, Bfield = num%Bfield)
          trans%el_alphabyT = trans%el_alphabyT/crys%T

          !delT field:
          call iterate_bte_el(num, el, crys, &
               self%el_rta_rates_ibz, self%el_field_term_T, self%el_response_T, ph_drag_term_T)
          !Enforce Kelvin-Onsager relation:
          !Fix "diffusion" part
          do icart = 1, 3
             I_diff(:,:,icart) = (el%ens(:,:) - el%chempot)/qe/crys%T*&
                  self%el_response_E(:,:,icart)
          end do
          !Correct "drag" part
          I_drag = self%el_response_T - I_diff
          call correct_I_drag(I_drag, trace(sum(trans%ph_alphabyT, dim = 1))/crys%dim, lambda)
          self%el_response_T = I_diff + lambda*I_drag

          !Calculate electron transport coefficients
          call calculate_transport_coeff('el', 'T', crys%T, el%spindeg, el%chempot, &
               el%ens, el%vels, crys%volume, el%wvmesh, self%el_response_T, sym, &
               trans%el_kappa0, trans%el_sigmaS, Bfield = num%Bfield)

          !Calculate electron transport scalars
          el_kappa0_scalar = trace(sum(trans%el_kappa0, dim = 1))/crys%dim
          el_sigmaS_scalar = trace(sum(trans%el_sigmaS, dim = 1))/crys%dim
          el_sigma_scalar = trace(sum(trans%el_sigma, dim = 1))/crys%dim
          el_alphabyT_scalar = trace(sum(trans%el_alphabyT, dim = 1))/crys%dim

          !Check convergence
          if(converged(el_kappa0_scalar_old, el_kappa0_scalar, num%conv_thres) .and. &
               converged(el_sigmaS_scalar_old, el_sigmaS_scalar, num%conv_thres) .and. &
               converged(el_sigma_scalar_old, el_sigma_scalar, num%conv_thres) .and. &
               converged(el_alphabyT_scalar_old, el_alphabyT_scalar, num%conv_thres)) then
             exit
          else
             el_kappa0_scalar_old = el_kappa0_scalar
             el_sigmaS_scalar_old = el_sigmaS_scalar
             el_sigma_scalar_old = el_sigma_scalar
             el_alphabyT_scalar_old = el_alphabyT_scalar
          end if
       end do

       !Calculate phonon transport scalar
       ph_kappa_scalar = trace(sum(trans%ph_kappa, dim = 1))/crys%dim
       ph_alphabyT_scalar = trace(sum(trans%ph_alphabyT, dim = 1))/crys%dim

       if(it_ph == 1) then
          !Print RTA band/branch resolved response functions
          ! Change to data output directory
          call chdir(trim(adjustl(Tdir)))
          call write2file_response('partdcpl_I0_', self%el_response_T, el%bandlist) !gradT, el
          call write2file_response('partdcpl_J0_', self%el_response_E, el%bandlist) !E, el
          ! Change back to cwd
          call chdir(trim(adjustl(num%cwd)))
       end if

       tot_alphabyT_scalar = el_alphabyT_scalar + ph_alphabyT_scalar
       KO_dev = 100.0_r64*abs(&
            (el_sigmaS_scalar - tot_alphabyT_scalar)/tot_alphabyT_scalar)

       if(this_image() == 1) then
          write(*,"(I3, A, 1E16.8, A, 1E16.8, A, 1E16.8, A, 1E16.8, &
               A, 1E16.8, A, 1E16.8, A, 1F6.3)") it_ph, "     ", el_kappa0_scalar, &
               "      ", el_sigmaS_scalar, "     ", ph_kappa_scalar, &
               "    ", el_sigma_scalar, "        ", el_alphabyT_scalar, &
               "         ", ph_alphabyT_scalar, "           ", KO_dev
       end if

       !Print out band resolved transport coefficients
       ! Change to data output directory
       call chdir(trim(adjustl(Tdir)))
       call append2file_transport_tensor('drag_ph_kappa_', it_ph, trans%ph_kappa)
       call append2file_transport_tensor('drag_ph_alphabyT_', it_ph, trans%ph_alphabyT)
       call append2file_transport_tensor('drag_el_sigmaS_', it_ph, trans%el_sigmaS, el%bandlist)
       call append2file_transport_tensor('drag_el_sigma_', it_ph, trans%el_sigma, el%bandlist)
       call append2file_transport_tensor('drag_el_alphabyT_', it_ph, trans%el_alphabyT, el%bandlist)
       call append2file_transport_tensor('drag_el_kappa0_', it_ph, trans%el_kappa0, el%bandlist)
       ! Change back to cwd
       call chdir(trim(adjustl(num%cwd)))

       !Check convergence
       if(converged(ph_kappa_scalar_old, ph_kappa_scalar, num%conv_thres) .and. &
            converged(ph_alphabyT_scalar_old, ph_alphabyT_scalar, num%conv_thres)) then

          !Print converged band/branch resolved response functions
          ! Change to data output directory
          call chdir(trim(adjustl(Tdir)))
          call write2file_response('drag_F0_', self%ph_response_T) !gradT, ph
          call write2file_response('drag_I0_', self%el_response_T, el%bandlist) !gradT, el
          call write2file_response('drag_G0_', self%ph_response_E) !E, ph
          call write2file_response('drag_J0_', self%el_response_E, el%bandlist) !E, el
          ! Change back to cwd
          call chdir(trim(adjustl(num%cwd)))
          exit
       else
          ph_kappa_scalar_old = ph_kappa_scalar
          ph_alphabyT_scalar_old = ph_alphabyT_scalar
       end if
    end do

    !Don't need these anymore
    deallocate(I_drag, I_diff, ph_drag_term_T, ph_drag_term_E)
    deallocate(widc, idc, ksint)

    call t%end_timer('Coupled e-ph BTEs')

    sync all

  contains

    subroutine correct_I_drag(I_drag, constraint, lambda)
      !! Subroutine to find scaling correction to I_drag.

      real(r64), intent(in) :: I_drag(:,:,:), constraint
      real(r64), intent(out) :: lambda

      !Internal variables
      integer(i64) :: it, maxiter
      real(r64) :: a, b, sigmaS(size(I_drag(1,:,1)), 3, 3),&
           thresh, sigmaS_scalar, dummy(size(I_drag(1,:,1)), 3, 3)

      a = 0.0_r64 !lower bound
      b = 2.0_r64 !upper bound
      maxiter = 100
      thresh = 1.0e-6_r64
      do it = 1, maxiter
         lambda = 0.5_r64*(a + b)
         !Calculate electron transport coefficients
         call calculate_transport_coeff('el', 'T', crys%T, el%spindeg, el%chempot, &
              el%ens, el%vels, crys%volume, el%wvmesh, lambda*I_drag, sym, &
              dummy, sigmaS)         
         sigmaS_scalar = trace(sum(sigmaS, dim = 1))/crys%dim

         if(abs(sigmaS_scalar - constraint) < thresh) then
            exit
         else if(abs(sigmaS_scalar) < abs(constraint)) then
            a = lambda
         else
            b = lambda
         end if
      end do
    end subroutine correct_I_drag

  end subroutine dragfull_ephbtes
  
  subroutine calculate_field_term(species, field, nequiv, ibz2fbz_map, &
       T, chempot, ens, vels, rta_rates_ibz, field_term, el_indexlist)
    !! Subroutine to calculate the field coupling term of the BTE.
    !!
    !! species Type of particle
    !! field Type of field
    !! nequiv List of the number of equivalent points for each IBZ wave vector
    !! ibz2fbz_map Map from an FBZ wave vectors to its IBZ wedge image
    !! T Temperature in K
    !! ens FBZ energies
    !! vels FBZ velocities
    !! chempot Chemical potential (should be 0 for phonons)
    !! rta_rates_ibz IBZ RTA scattering rates
    !! field_term FBZ field-coupling term of the BTE
    !! el_indexlist [Optional] 

    character(len = 2), intent(in) :: species
    character(len = 1), intent(in) :: field
    integer(i64), intent(in) :: nequiv(:), ibz2fbz_map(:,:,:)
    real(r64), intent(in) :: T, chempot, ens(:,:), vels(:,:,:), rta_rates_ibz(:,:)
    real(r64), allocatable, intent(out) :: field_term(:,:,:)
    integer(i64), intent(in), optional :: el_indexlist(:)

    !Local variables
    integer(i64) :: ik_ibz, ik_fbz, ieq, ib, nk_ibz, nk, nbands, pow, &
         chunk, num_active_images, start, end
    real(r64) :: A
    logical :: trivial_case

    !Set constant and power of energy depending on species and field type
    if(species == 'ph') then
       A = 1.0_r64/T
       pow = 1
       if(chempot /= 0.0_r64) then
          call exit_with_message("Phonon chemical potential non-zero in calculate_field_term. Exiting.")
       end if
    else if(species == 'el') then
       if(field == 'T') then
          A = 1.0_r64/T
          pow = 1
       else if(field == 'E') then
          A = qe
          pow = 0
       else
          call exit_with_message("Unknown field type in calculate_field_term. Exiting.")
       end if
    else
       call exit_with_message("Unknown particle species in calculate_field_term. Exiting.")
    end if

    !Number of IBZ wave vectors
    nk_ibz = size(rta_rates_ibz(:,1))

    !Number of FBZ wave vectors
    nk = size(ens(:,1))

    !Number of bands
    nbands = size(ens(1,:))

    !Allocate and initialize field term
    allocate(field_term(nk, nbands, 3))
    field_term(:,:,:) = 0.0_r64

    !No field-coupling case
    trivial_case = species == 'ph' .and. field == 'E'

    if(.not. trivial_case) then
       !Divide IBZ states among images
       call distribute_points(nk_ibz, chunk, start, end, num_active_images)

       !Only work with the active images
       if(this_image() <= num_active_images) then
          do ik_ibz = start, end
             do ieq = 1, nequiv(ik_ibz)
                if(species == 'ph') then
                   ik_fbz = ibz2fbz_map(ieq, ik_ibz, 2)
                else
                   !Find index of electron in indexlist
                   call binsearch(el_indexlist, ibz2fbz_map(ieq, ik_ibz, 2), ik_fbz)
                end if
                do ib = 1, nbands
                   if(rta_rates_ibz(ik_ibz, ib) /= 0.0_r64) then
                      field_term(ik_fbz, ib, :) = A*vels(ik_fbz, ib, :)*&
                           (ens(ik_fbz, ib) - chempot)**pow/rta_rates_ibz(ik_ibz, ib)
                   end if
                end do
             end do
          end do
       end if
       
       !Reduce field term
       !Units:
       ! nm.eV/K for phonons, gradT-field
       ! nm.eV/K for electrons, gradT-field
       ! nm.C for electrons, E-field
       sync all
       call co_sum(field_term)
       sync all
    end if
  end subroutine calculate_field_term

  subroutine iterate_bte_ph(T, num, crys, ph, el, rta_rates_ibz, &
       field_term, response_ph, response_el)
    !! Subroutine to iterate the phonon BTE one step.
    !! 
    !! T Temperature in K
    !! num Numerics object
    !! crys Crystal object
    !! ph Phonon object
    !! el Electron object
    !! rta_rates_ibz Phonon RTA scattering rates
    !! field_term Phonon field coupling term
    !! response_ph Phonon response function
    !! response_el Electron response function

    type(phonon), intent(in) :: ph
    type(electron), intent(in) :: el
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    real(r64), intent(in) :: T, rta_rates_ibz(:,:), field_term(:,:,:)
    real(r64), intent(in), optional :: response_el(:,:,:)
    real(r64), intent(inout) :: response_ph(:,:,:)

    !Local variables
    integer(i64) :: nstates_irred, chunk, istate1, numbranches, s1, &
         iq1_ibz, ieq, iq1_sym, iq1_fbz, iproc, iq2, s2, iq3, s3, nq, &
         num_active_images, numbands, ik, ikp, m, n, nprocs_phe, aux1, aux2, &
         nprocs_3ph_plus, nprocs_3ph_minus, start, end
    integer(i64), allocatable :: istate2_plus(:), istate3_plus(:), &
         istate2_minus(:), istate3_minus(:), istate_el1(:), istate_el2(:)
    real(r64) :: tau_ibz
    real(r64), allocatable :: Wp(:), Wm(:), Y(:), response_ph_reduce(:,:,:)
    character(len = 1024) :: filepath_Wm, filepath_Wp, filepath_Y, tag

    !Set output directory of transition probilities
    write(tag, "(E9.3)") T
    
    if(present(response_el)) then
       !Number of electron bands
       numbands = size(response_el(1,:,1))
    end if
    
    !Number of phonon branches
    numbranches = size(rta_rates_ibz(1,:))

    !Number of FBZ wave vectors
    nq = size(field_term(:,1,1))
    
    !Total number of IBZ states
    nstates_irred = size(rta_rates_ibz(:,1))*numbranches
    
    !Allocate and initialize response reduction array
    allocate(response_ph_reduce(nq, numbranches, 3))
    response_ph_reduce(:,:,:) = 0.0_r64
    
    !Divide phonon states among images
    call distribute_points(nstates_irred, chunk, start, end, num_active_images)

    !Only work with the active images
    if(this_image() <= num_active_images) then

       ! First we add self interactions comming from isotopic and
       ! substitution
       if (ph%xiso%nels .ne. 0) then
          do iproc = 1, ph%xiso%nels
               ! Get states information
               call demux_state(ph%xiso%indexes(iproc,1), numbranches, s1, iq1_ibz)
               call demux_state(ph%xiso%indexes(iproc,2), numbranches, s2, iq2)
               !Now iterate over the images
               do ieq = 1, ph%nequiv(iq1_ibz)
                   iq1_sym = ph%ibz2fbz_map(ieq, iq1_ibz, 1) !symmetry
                   iq1_fbz = ph%ibz2fbz_map(ieq, iq1_ibz, 2) !image due to symmetry
                   response_ph_reduce(iq1_fbz, s1, :) = response_ph_reduce(iq1_fbz, s1, :) + &
                       ph%xiso%matel(iproc) * response_ph(ph%equiv_map(iq1_sym, iq2), s2, :)
               end do
          end do ! iproc
       end if
       
       ! Now subs (same as isotopic)
       if (ph%xsubs%nels .ne. 0) then
          do iproc = 1, ph%xsubs%nels
               ! Get states information
               call demux_state(ph%xsubs%indexes(iproc,1), numbranches, s1, iq1_ibz)
               call demux_state(ph%xsubs%indexes(iproc,2), numbranches, s2, iq2)
               !Now iterate over the images
               do ieq = 1, ph%nequiv(iq1_ibz)
                   iq1_sym = ph%ibz2fbz_map(ieq, iq1_ibz, 1) !symmetry
                   iq1_fbz = ph%ibz2fbz_map(ieq, iq1_ibz, 2) !image due to symmetry
                   response_ph_reduce(iq1_fbz, s1, :) = response_ph_reduce(iq1_fbz, s1, :) + &
                       ph%xsubs%matel(iproc) * response_ph(ph%equiv_map(iq1_sym, iq2), s2, :)
               end do
          end do ! iproc
       end if
       !Run over first phonon IBZ states
       do istate1 = start, end
          !Demux state index into branch (s) and wave vector (iq1_ibz) indices
          call demux_state(istate1, numbranches, s1, iq1_ibz)

          !Set file tag
          write(tag, '(I9)') istate1
          
          !RTA lifetime
          tau_ibz = 0.0_r64
          if(rta_rates_ibz(iq1_ibz, s1) /= 0.0_r64) then
             tau_ibz = 1.0_r64/rta_rates_ibz(iq1_ibz, s1)
          end if
          
          if(num%W_OTF) then
             call calculate_W3ph_OTF(ph, num, istate1, T, &
                  Wm, Wp, istate2_plus, istate3_plus, istate2_minus, istate3_minus)
             nprocs_3ph_plus = size(Wp); nprocs_3ph_minus = size(Wm)
          else
             !Set W+ filename
             filepath_Wp = trim(adjustl(num%Wdir))//'/Wp.istate'//trim(adjustl(tag))

             !Read W+ from file
             if(allocated(Wp)) deallocate(Wp)
             if(allocated(istate2_plus)) deallocate(istate2_plus)
             if(allocated(istate3_plus)) deallocate(istate3_plus)
             call read_transition_probs_e(trim(adjustl(filepath_Wp)), nprocs_3ph_plus, Wp, &
                  istate2_plus, istate3_plus)

             !Set W- filename
             filepath_Wm = trim(adjustl(num%Wdir))//'/Wm.istate'//trim(adjustl(tag))

             !Read W- from file
             if(allocated(Wm)) deallocate(Wm)
             if(allocated(istate2_minus)) deallocate(istate2_minus)
             if(allocated(istate3_minus)) deallocate(istate3_minus)
             call read_transition_probs_e(trim(adjustl(filepath_Wm)), nprocs_3ph_minus, Wm, &
                  istate2_minus, istate3_minus)
          end if
          
          if(present(response_el)) then
             if(num%Y_OTF) then
                call calculate_Y_OTF(el, ph, num, crys, istate1, T, Y, istate_el1, istate_el2)
                nprocs_phe = size(Y)
             else
                !Set Y filename
                filepath_Y = trim(adjustl(num%Ydir))//'/Y.istate'//trim(adjustl(tag))

                !Read Y from file
                if(allocated(Y)) deallocate(Y)
                if(allocated(istate_el1)) deallocate(istate_el1)
                if(allocated(istate_el2)) deallocate(istate_el2)
                call read_transition_probs_e(trim(adjustl(filepath_Y)), nprocs_phe, Y, &
                     istate_el1, istate_el2)
             end if
          end if

          !Sum over the number of equivalent q-points of the IBZ point
          do ieq = 1, ph%nequiv(iq1_ibz)
             iq1_sym = ph%ibz2fbz_map(ieq, iq1_ibz, 1) !symmetry
             iq1_fbz = ph%ibz2fbz_map(ieq, iq1_ibz, 2) !image due to symmetry

             !Sum over scattering processes
             !Self contribution from plus processes:
             do iproc = 1, nprocs_3ph_plus
                !Grab 2nd and 3rd phonons
                call demux_state(istate2_plus(iproc), numbranches, s2, iq2)
                call demux_state(istate3_plus(iproc), numbranches, s3, iq3)

                response_ph_reduce(iq1_fbz, s1, :) = response_ph_reduce(iq1_fbz, s1, :) + &
                     Wp(iproc)*(response_ph(ph%equiv_map(iq1_sym, iq3), s3, :) - &
                     response_ph(ph%equiv_map(iq1_sym, iq2), s2, :))
             end do

             !Self contribution from minus processes:
             do iproc = 1, nprocs_3ph_minus
                !Grab 2nd and 3rd phonons
                call demux_state(istate2_minus(iproc), numbranches, s2, iq2)
                call demux_state(istate3_minus(iproc), numbranches, s3, iq3)

                response_ph_reduce(iq1_fbz, s1, :) = response_ph_reduce(iq1_fbz, s1, :) + &
                     0.5_r64*Wm(iproc)*(response_ph(ph%equiv_map(iq1_sym, iq3), s3, :) + &
                     response_ph(ph%equiv_map(iq1_sym, iq2), s2, :))
             end do

             !Drag contribution:

             if(present(response_el)) then
                do iproc = 1, nprocs_phe
                   !Grab initial and final electron states
                   call demux_state(istate_el1(iproc), numbands, m, ik)
                   call demux_state(istate_el2(iproc), numbands, n, ikp)

                   !Find image of electron wave vector due to the current symmetry
                   call binsearch(el%indexlist, el%equiv_map(iq1_sym, ik), aux1)
                   call binsearch(el%indexlist, el%equiv_map(iq1_sym, ikp), aux2)

                   response_ph_reduce(iq1_fbz, s1, :) = response_ph_reduce(iq1_fbz, s1, :) + &
                        el%spindeg*Y(iproc)*(response_el(aux2, n, :) - response_el(aux1, m, :))
                end do
             end if

             !Iterate BTE
             response_ph_reduce(iq1_fbz, s1, :) = field_term(iq1_fbz, s1, :) + &
                  response_ph_reduce(iq1_fbz, s1, :)*tau_ibz          
          end do
       end do
    end if

    !Update the response function
    sync all
    call co_sum(response_ph_reduce)
    sync all
    response_ph = response_ph_reduce

    !Symmetrize response function
    do iq1_fbz = 1, nq
       response_ph(iq1_fbz,:,:)=transpose(&
            matmul(ph%symmetrizers(:,:,iq1_fbz),transpose(response_ph(iq1_fbz,:,:))))
    end do
  end subroutine iterate_bte_ph

  subroutine iterate_bte_el(num, el, crys, rta_rates_ibz, field_term, &
       response_el, ph_drag_term)
    !! Subroutine to iterate the electron BTE one step.
    !! 
    !! T Temperature in K
    !! drag Is drag included?
    !! el Electron object
    !! sym Symmetry
    !! rta_rates_ibz Electron RTA scattering rates
    !! field_term Electron field coupling term
    !! response_el Electron response function
    !! ph_drag_term Phonon drag term
    
    type(electron), intent(in) :: el
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    !real(r64), intent(in) :: T, rta_rates_ibz(:,:), field_term(:,:,:)
    real(r64), intent(in) :: rta_rates_ibz(:,:), field_term(:,:,:)
    real(r64), intent(in), optional :: ph_drag_term(:,:,:)
    real(r64), intent(inout) :: response_el(:,:,:)

    !Local variables
    integer(i64) :: nstates_irred, nprocs, chunk, istate, numbands, numbranches, &
         ik_ibz, m, ieq, ik_sym, ik_fbz, iproc, ikp, n, nk, num_active_images, &
         aux, aux2, aux3, aux4, start, end, nprocs_echimp, neg_ik_fbz, nprocs_ee, &
         n2, n3, n4, ik2, ik3, ik4
    integer :: i, j
    integer(i64), allocatable :: istate_el(:), istate_ph(:), istate_el_echimp(:), &
         istate_el_ee2(:), istate_el_ee3(:), istate_el_ee4(:)
         
    real(r64) :: tau_ibz, Bfield_unit_factor, eps
    real(r64), allocatable :: Xphplus(:), Xphminus(:),  Xchimp(:), Xee(:), &
         response_el_reduce(:,:,:), Delk_response(:, :, :, :), scratch(:, :)
    character(1024) :: filepath_Xphminus, filepath_Xphplus, filepath_Xechimp, tag

    !Factor to make B-field term have units of
    !C.nm for the E-field BTE and
    !eV.nm/K for the gradT-field BTE.
    Bfield_unit_factor = 1.0e-6_r64/hbar_eVps
    
    !Set output directory of transition probilities
    write(tag, "(E9.3)") crys%T
    
    !Number of electron bands
    numbands = size(rta_rates_ibz(1,:))

    !Number of in-window FBZ wave vectors
    nk = size(field_term(:,1,1))

    !Total number of IBZ states
    nstates_irred = size(rta_rates_ibz(:,1))*numbands

    if(present(ph_drag_term)) then
       !Number of phonon branches
       numbranches = size(ph_drag_term(1,:,1))
    end if

    !Bfield related
    !Allocate Jacobian of response function
    if(num%Bfield_on) allocate(Delk_response(nk, numbands, 3, 3))

    allocate(scratch(numbands, 3))
    
    !Allocate and initialize response reduction array
    allocate(response_el_reduce(nk, numbands, 3))
    response_el_reduce(:,:,:) = 0.0_r64
    
    !Divide electron states among images
    call distribute_points(nstates_irred, chunk, start, end, num_active_images)

    !Compute the Jacobian of the electronic response
    if(num%Bfield_on) then
       !print*, 'B-field is on. B-field = ', num%Bfield
       !TODO The call below will be parallel and blocking.
       call Jacobian(response_el, Delk_response, crys%lattvecs, &
            el%wvmesh, el%indexlist, crys%dim, blocks = .true.)
    end if
    
    !Only work with the active images
    if(this_image() <= num_active_images) then
       !Run over electron IBZ states
       do istate = start, end
          !Demux state index into band (m) and wave vector (ik_ibz) indices
          call demux_state(istate, numbands, m, ik_ibz)
          
          !Apply energy window to initial (IBZ blocks) electron
          if(abs(el%ens_irred(ik_ibz, m) - el%enref) > el%fsthick) cycle

          !RTA lifetime
          tau_ibz = 0.0_r64
          if(rta_rates_ibz(ik_ibz, m) /= 0.0_r64) then
             tau_ibz = 1.0_r64/rta_rates_ibz(ik_ibz, m)
          end if
          
          !Set X+ filename
          write(tag, '(I9)') istate
          filepath_Xphplus = trim(adjustl(num%Xdir))//'/Xplus.istate'//trim(adjustl(tag))

          !Read X+ from file
          call read_transition_probs_e(trim(adjustl(filepath_Xphplus)), nprocs, Xphplus, &
               istate_el, istate_ph)

          !Set X- filename
          write(tag, '(I9)') istate
          filepath_Xphminus = trim(adjustl(num%Xdir))//'/Xminus.istate'//trim(adjustl(tag))

          !Read X- from file
          call read_transition_probs_e(trim(adjustl(filepath_Xphminus)), nprocs, Xphminus)

          !Read Xchimp from file
          if(num%elchimp) then
             !Set Xchimp filename
             write(tag, '(I9)') istate
             filepath_Xechimp = trim(adjustl(num%Xdir))//'/Xchimp.istate'//trim(adjustl(tag))
             call read_transition_probs_e(trim(adjustl(filepath_Xechimp)), nprocs_echimp, Xchimp, &
                  istate_el_echimp)
          end if
          
          !Electron-electron transition rates (for now on-the-fly computation)
          if(num%elel) then
             call calculate_Xee_OTF(el, num, istate, crys, Xee, &
                  istate_el_ee2, istate_el_ee3, istate_el_ee4)
             nprocs_ee = size(Xee)
          end if
          
          !Sum over the number of equivalent k-points of the IBZ point
          do ieq = 1, el%nequiv(ik_ibz)
             ik_sym = el%ibz2fbz_map(ieq, ik_ibz, 1) !symmetry
             call binsearch(el%indexlist, el%ibz2fbz_map(ieq, ik_ibz, 2), ik_fbz)

             !Sum over scattering processes
             do iproc = 1, nprocs
                !Grab the final electron and, if needed, the interacting phonon
                call demux_state(istate_el(iproc), numbands, n, ikp)

                !Self contribution:

                !Find image of final electron wave vector due to the current symmetry
                call binsearch(el%indexlist, el%equiv_map(ik_sym, ikp), aux)

                response_el_reduce(ik_fbz, m, :) = response_el_reduce(ik_fbz, m, :) + &
                     response_el(aux, n, :)*(Xphplus(iproc) + Xphminus(iproc))
             end do
             
             !Add charged impurity contribution to the self consistent term
             if(num%elchimp) then
                do iproc = 1, nprocs_echimp
                   !Grab the final electron and, if needed, the interacting phonon
                   call demux_state(istate_el_echimp(iproc), numbands, n, ikp)
                   
                   !Self contribution:
                   !Find image of final electron wave vector due to the current symmetry
                   call binsearch(el%indexlist, el%equiv_map(ik_sym, ikp), aux)
                   
                   response_el_reduce(ik_fbz, m, :) = response_el_reduce(ik_fbz, m, :) + &
                        response_el(aux, n, :) * Xchimp(iproc)
                end do
             end if

             !Add electron-electron scattering contribution to the self consistent term
             if(num%elel) then
                do iproc = 1, nprocs_ee
                   !Electron 2
                   call demux_state(istate_el_ee2(iproc), numbands, n2, ik2)
                   !Find image of k2 due to the current symmetry
                   call binsearch(el%indexlist, el%equiv_map(ik_sym, ik2), aux2)

                   !Electron 3
                   call demux_state(istate_el_ee3(iproc), numbands, n3, ik3)
                   !Find image of k3 due to the current symmetry
                   call binsearch(el%indexlist, el%equiv_map(ik_sym, ik3), aux3)

                   !Electron 4
                   call demux_state(istate_el_ee4(iproc), numbands, n4, ik4)
                   !Find image of k4 due to the current symmetry
                   call binsearch(el%indexlist, el%equiv_map(ik_sym, ik4), aux4)
                   
                   response_el_reduce(ik_fbz, m, :) = response_el_reduce(ik_fbz, m, :) + &
                        Xee(iproc)*(-response_el(aux2, n2, :) + response_el(aux3, n3, :) + &
                                     response_el(aux4, n4, :))
                end do
             end if

             !B-field term
             if(num%Bfield_on) then
                response_el_reduce(ik_fbz, m, :) = response_el_reduce(ik_fbz, m, :) + &
                     Bfield_unit_factor*matmul( &
                     Delk_response(ik_fbz, m, :, :), cross_product(el%vels(ik_fbz, m, :), num%Bfield))
             end if
             
             !Iterate BTE
             response_el_reduce(ik_fbz, m, :) = field_term(ik_fbz, m, :) + &
                  response_el_reduce(ik_fbz, m, :)*tau_ibz
          end do
       end do
    end if
    
    !Update the response function
    sync all
    call co_sum(response_el_reduce)
    sync all
    response_el = response_el_reduce
    
    if(present(ph_drag_term)) then
       !Drag contribution:
       response_el(:,:,:) = response_el(:,:,:) + ph_drag_term(:,:,:)
    end if

    !TODO The following has to be generalized in the presence of a B-field
    if(.not. num%Bfield_on) then
       !Symmetrize response function
       do ik_fbz = 1, nk
          response_el(ik_fbz, :, :) = transpose(&
               matmul(el%symmetrizers(:, :, ik_fbz), transpose(response_el(ik_fbz, :, :))))
       end do
    else
       !TODO
    end if
  end subroutine iterate_bte_el

  subroutine calculate_phonon_drag(num, el, ph, idc, widc, sym, rta_rates_ibz, response_ph, &
                                   ph_drag_term)
    !! Subroutine to calculate the phonon drag term.
    !! 
    !! num Numerics object
    !! el Electron object
    !! ph Phonon object
    !! idc corners in the coarse mesh for the refined mesh.
    !! widc weights of the corners for interpolation of values in corse mesh to the refined one
    !! sym Symmetry
    !! rta_rates_ibz Electron RTA scattering rates
    !! response_ph Phonon response function
    !! ph_drag_term Phonon drag term


    type(electron), intent(in) :: el
    type(phonon), intent(in) :: ph
    type(numerics), intent(in) :: num
    type(symmetry), intent(in) :: sym
    integer(i64), intent(in) :: idc(:,:)
    real(r64), intent(in) :: rta_rates_ibz(:,:), response_ph(:,:,:), widc(:,:)
    real(r64), intent(out) :: ph_drag_term(:,:,:)

    !Local variables
    integer(i64) :: nstates_irred, nprocs, chunk, istate, numbands, numbranches, &
         ik_ibz, m, ieq, ik_sym, ik_fbz, iproc, iq, s, nk, num_active_images, &
         fineq_indvec(3), start, end, iq2inter
    integer(i64), allocatable :: istate_el(:), istate_ph(:)
    real(r64) :: tau_ibz, ForG(3)
    real(r64), allocatable :: Xplus(:), Xminus(:), ph_drag_term_reduce(:,:,:)
    character(1024) :: filepath_Xminus, filepath_Xplus, tag
    
    !Number of electron bands
    numbands = el%numbands

    !Number of in-window FBZ wave vectors
    nk = el%nwv

    !Total number of IBZ states
    nstates_irred = el%nwv_irred*numbands
    
    !Number of phonon branches
    numbranches = ph%numbands

    !Allocate and initialize response reduction array
    allocate(ph_drag_term_reduce(nk, numbands, 3))
    ph_drag_term_reduce(:,:,:) = 0.0_r64

    !Divide electron states among images
    call distribute_points(nstates_irred, chunk, start, end, num_active_images)

    !Only work with the active images
    if(this_image() <= num_active_images) then
       !Run over electron IBZ states
       do istate = start, end
          !Demux state index into band (m) and wave vector (ik_ibz) indices
          call demux_state(istate, numbands, m, ik_ibz)

          !Apply energy window to initial (IBZ blocks) electron
          if(abs(el%ens_irred(ik_ibz, m) - el%enref) > el%fsthick) cycle

          !RTA lifetime
          tau_ibz = 0.0_r64
          if(rta_rates_ibz(ik_ibz, m) /= 0.0_r64) then
             tau_ibz = 1.0_r64/rta_rates_ibz(ik_ibz, m)
          end if

          !Set X+ filename
          write(tag, '(I9)') istate
          filepath_Xplus = trim(adjustl(num%Xdir))//'/Xplus.istate'//trim(adjustl(tag))

          !Read X+ from file
          call read_transition_probs_e(trim(adjustl(filepath_Xplus)), nprocs, Xplus, &
               istate_el, istate_ph)

          !Set X- filename
          write(tag, '(I9)') istate
          filepath_Xminus = trim(adjustl(num%Xdir))//'/Xminus.istate'//trim(adjustl(tag))

          !Read X- from file
          call read_transition_probs_e(trim(adjustl(filepath_Xminus)), nprocs, Xminus)

          !Sum over the number of equivalent k-points of the IBZ point
          do ieq = 1, el%nequiv(ik_ibz)
             ik_sym = el%ibz2fbz_map(ieq, ik_ibz, 1) !symmetry
             call binsearch(el%indexlist, el%ibz2fbz_map(ieq, ik_ibz, 2), ik_fbz)

             !Sum over scattering processes
             do iproc = 1, nprocs
                if(istate_ph(iproc) < 0) then !This phonon is on the (fine) electron mesh
                   call demux_state(-istate_ph(iproc), numbranches, s, iq)
                   iq = -iq !Keep the negative tag
                else !This phonon is on the phonon mesh
                   call demux_state(istate_ph(iproc), numbranches, s, iq)
                end if

                !Drag contribution:             
                if(iq < 0) then !Need to interpolate on this point
                   !Calculate the fine mesh wave vector, 0-based index vector
                   call demux_vector(-iq, fineq_indvec, el%wvmesh, 0_i64)

                   !Find image of phonon wave vector due to the current symmetry
                   fineq_indvec = modulo( &
                        nint(matmul(sym%qrotations(:, :, ik_sym), fineq_indvec)), el%wvmesh)

                   !Interpolate response function on this wave vector using precomputed tabulated weights
                   !and points. I note that response_ph(:, s, :) is not contiguous in memory.
                   iq2inter = mux_vector(fineq_indvec,el%wvmesh, 0_i64)
                   call interpolate_using_precomputed(idc(iq2inter,:), widc(iq2inter,:),&
                                                      response_ph(:, s, :), ForG(:))
                else
                   !F(q) or G(q)
                   ForG(:) = response_ph(ph%equiv_map(ik_sym, iq), s, :)
                end if
                !Here we use the fact that F(-q) = -F(q) and G(-q) = -G(q)
                ph_drag_term_reduce(ik_fbz, m, :) = ph_drag_term_reduce(ik_fbz, m, :) - &
                     ForG(:)*(Xplus(iproc) + Xminus(iproc))
             end do

             !Multiply life time factor 
             ph_drag_term_reduce(ik_fbz, m, :) = ph_drag_term_reduce(ik_fbz, m, :)*tau_ibz
          end do
       end do
    end if

    !Reduce from all images
    sync all
    call co_sum(ph_drag_term_reduce)
    sync all
    ph_drag_term = ph_drag_term_reduce
  end subroutine calculate_phonon_drag

  pure logical function converged(oldval, newval, thres)
    !! Function to check if newval is the same as oldval

    real(r64), intent(in) :: oldval, newval, thres

    converged = .False.

    if(newval == oldval) then
       converged = .True.
    else if(oldval /= 0.0_r64) then
       if(abs(newval - oldval)/abs(oldval) < thres) converged = .True.
    end if
  end function converged
      
  !TODO: Move this to the Julia script.
  subroutine post_process(self, num, crys, sym, ph, el)
    !! Subroutine to post-process results of the BTEs.

    class(bte), intent(inout) :: self
    type(numerics), intent(in) :: num
    type(crystal), intent(in) :: crys
    type(symmetry), intent(in) :: sym
    type(phonon), intent(in) :: ph
    type(electron), intent(in), optional :: el

    !Local variables
    real(r64), allocatable :: ph_en_grid(:), el_en_grid(:), ph_kappa(:,:,:,:), dummy(:,:,:,:), &
         el_kappa0(:,:,:,:), el_sigmaS(:,:,:,:), el_sigma(:,:,:,:), el_alphabyT(:,:,:,:), &
         ph_alphabyT(:,:,:,:), ph_scalar_mfps(:, :), &
         ph_mfp_sampling_grid(:), ph_q_sampling_grid(:), &
         ph_kappa_cumulative_mfp(:, :, :, :), ph_kappa_cumulative_q(:, :, :, :)
    real(r64) :: ph_abs_qs(ph%nwv)
    character(len = 1024) :: tag, Tdir, numcols
    integer(i64) :: ik, ib

    !Calculate electron and/or phonon sampling energy grid
    call linspace(ph_en_grid, num%ph_en_min, num%ph_en_max, num%ph_en_num)
    call linspace(el_en_grid, num%el_en_min, num%el_en_max, num%el_en_num)
    
    !Write energy grids to file
    call write2file_rank1_real("ph.en_grid", ph_en_grid)
    call write2file_rank1_real("el.en_grid", el_en_grid)

    !Calcualte |q|_FBZ
    ph_abs_qs = [(qdist(ph%wavevecs(ik, :), crys%reclattvecs), ik = 1, ph%nwv)]

    !Print out IBZ |q|
    if(this_image() == 1) then
       write(numcols, "(I0)") ph%numbands
       open(1, file = "ph.abs_q_ibz", status = "replace")
       do ik = 1, ph%nwv_irred
          write(1, "(E20.10)") &
               ph_abs_qs(ph%indexlist_irred(ik))
       end do
       close(1)
    end if
    sync all
    
    !Calculate phonon |q|-sampling grid
    ! using a linear grid with a 15% increased |q| value. 
    call linspace(ph_q_sampling_grid, 0.0_r64, 1.5_r64*maxval(ph_abs_qs), num%ph_abs_q_npts)

    !Write the sampling mfps to file
    call write2file_rank1_real("ph_abs_q_sampling", ph_q_sampling_grid)

    !Change to T-dependent directory
    write(tag, "(E9.3)") crys%T
    Tdir = trim(adjustl(num%cwd))//'/T'//trim(adjustl(tag))
    call chdir(trim(adjustl(Tdir)))
        
    !Decoupled electron BTE
    if(.not. num%onlyphbte) then
       call print_message("Decoupled electron BTE:")
       call print_message("---------------------")

       !gradT:
       call print_message("gradT field:")

       ! RTA:
       call print_message(" Calculating RTA electron kappa0 and sigmaS...")

       !  Allocate response function
       allocate(self%el_response_T(el%nwv, el%numbands, 3))

       !  Read response function
       call readfile_response('RTA_I0_', self%el_response_T, el%bandlist)

       !  Allocate spectral transport coefficients
       allocate(el_kappa0(el%numbands, 3, 3, num%el_en_num), &
            el_sigmaS(el%numbands, 3, 3, num%el_en_num))

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'T', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_T, el_en_grid, num%tetrahedra, sym, &
            el_kappa0, el_sigmaS)

       !  Write spectral electron kappa
       call write2file_spectral_tensor('RTA_el_kappa0_spectral_', el_kappa0, el%bandlist)

       !  Write spectral electron sigmaS
       call write2file_spectral_tensor('RTA_el_sigmaS_spectral_', el_sigmaS, el%bandlist)
       !------------------------------------------------------------------!

       ! Iterated:
       call print_message(" Calculating iterated electron kappa0 and sigmaS...")

       !  Read response function
       call readfile_response('nodrag_I0_', self%el_response_T, el%bandlist)

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'T', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_T, el_en_grid, num%tetrahedra, sym, &
            el_kappa0, el_sigmaS)

       !  Write spectral electron kappa
       call write2file_spectral_tensor('nodrag_iterated_el_kappa0_spectral_', el_kappa0, el%bandlist)

       !  Write spectral electron sigmaS
       call write2file_spectral_tensor('nodrag_iterated_el_sigmaS_spectral_', el_sigmaS, el%bandlist)

       !  Release memory
       deallocate(self%el_response_T, el_kappa0, el_sigmaS)
       !------------------------------------------------------------------!

       !E:
       call print_message("E field:")

       ! RTA:
       call print_message(" Calculating RTA electron sigma and alpha/T...")

       !  Allocate response function
       allocate(self%el_response_E(el%nwv, el%numbands, 3))

       !  Read response function
       call readfile_response('RTA_J0_', self%el_response_E, el%bandlist)

       !  Allocate spectral transport coefficients
       allocate(el_sigma(el%numbands, 3, 3, num%el_en_num), &
            el_alphabyT(el%numbands, 3, 3, num%el_en_num))

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'E', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_E, el_en_grid, num%tetrahedra, sym, &
            el_alphabyT, el_sigma)
       el_alphabyT = el_alphabyT/crys%T

       !  Write spectral electron alpha/T
       call write2file_spectral_tensor('RTA_el_alphabyT_spectral_', el_alphabyT, el%bandlist)

       !  Write spectral electron sigma
       call write2file_spectral_tensor('RTA_el_sigma_spectral_', el_sigma, el%bandlist)
       !------------------------------------------------------------------!

       ! Iterated:
       call print_message(" Calculating iterated electron sigma and alpha/T...")

       !  Read response function
       call readfile_response('nodrag_J0_', self%el_response_E, el%bandlist)

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'E', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_E, el_en_grid, num%tetrahedra, sym, &
            el_alphabyT, el_sigma)
       el_alphabyT = el_alphabyT/crys%T

       !  Write spectral electron alpha/T
       call write2file_spectral_tensor('nodrag_iterated_el_alphabyT_spectral_', el_alphabyT, el%bandlist)

       !  Write spectral electron sigma
       call write2file_spectral_tensor('nodrag_iterated_el_sigma_spectral_', el_sigma, el%bandlist)

       !  Release memory
       deallocate(self%el_response_E, el_alphabyT, el_sigma)
    end if

    !Decoupled phonon BTE
    if(.not. num%onlyebte) then
       call print_message("Decoupled phonon BTE:")
       call print_message("---------------------")

       !gradT:
       call print_message("gradT field:")

       ! RTA:
       call print_message(" Calculating RTA phonon kappa...")

       !  Allocate response function
       allocate(self%ph_response_T(ph%nwv, ph%numbands, 3))

       !  Read response function
       call readfile_response('RTA_F0_', self%ph_response_T)

       !  Allocate spectral transport coefficients
       allocate(ph_kappa(ph%numbands, 3, 3, num%ph_en_num), &
            dummy(ph%numbands, 3, 3, num%ph_en_num))

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(ph, 'T', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
            crys%volume, self%ph_response_T, ph_en_grid, num%tetrahedra, sym, ph_kappa, dummy)

       !  Write spectral phonon kappa
       call write2file_spectral_tensor('RTA_ph_kappa_spectral_', ph_kappa)
       !------------------------------------------------------------------!

       ! Iterated:
       call print_message(" Calculating iterated phonon kappa...")

       !  Read response function
       call readfile_response('nodrag_F0_', self%ph_response_T)

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(ph, 'T', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
            crys%volume, self%ph_response_T, ph_en_grid, num%tetrahedra, sym, ph_kappa, dummy)

       !  Write spectral phonon kappa
       call write2file_spectral_tensor('nodrag_iterated_ph_kappa_spectral_', ph_kappa)

       !  Calculate scalar phonon mean-free-paths(mfps) for the grad-T field [T-dependent quantity]
       allocate(ph_scalar_mfps(ph%nwv, ph%numbands))
       ph_scalar_mfps = 0.0_r64
       
       do ib = 1, ph%numbands
          do ik = 1, ph%nwv
             ph_scalar_mfps(ik, ib) = &
                  dot_product(self%ph_response_T(ik, ib, :), ph%vels(ik, ib, :)) &
                  /twonorm(ph%vels(ik, ib, :))
          end do
       end do
       ph_scalar_mfps = ph_scalar_mfps/kB !nm
       ph_scalar_mfps(1, :) = 0.0_r64 !handle gamma point modes 
       
       !  Print out IBZ mfps
       if(this_image() == 1) then
          write(numcols, "(I0)") ph%numbands
          open(1, file = "nodrag_iterated_ph_mfps_ibz", status = "replace")
          do ik = 1, ph%nwv_irred
             write(1, "(" // trim(adjustl(numcols)) // "E20.10)") &
                  ph_scalar_mfps(ph%indexlist_irred(ik), :)
          end do
          close(1)
       end if
       sync all
       
       !  Calculate phonon mfp sampling grid [T-dependent quantity]
       
       !  Using a log grid with a 50% increased maximum mfp value. 
       call linspace(ph_mfp_sampling_grid, -6.0_r64, log10(1.5_r64*maxval(ph_scalar_mfps)), num%ph_mfp_npts)
       ph_mfp_sampling_grid = 10.0_r64**ph_mfp_sampling_grid

       !  Write the sampling mfps to file
       call write2file_rank1_real("nodrag_iterated_ph_mfps_sampling", ph_mfp_sampling_grid)

       !  Allocate cumulative kappa wrt mfp
       allocate(ph_kappa_cumulative_mfp(ph%numbands, 3, 3, num%ph_mfp_npts))

       !  Allocate cumulative kappa wrt |q|
       allocate(ph_kappa_cumulative_q(ph%numbands, 3, 3, num%ph_abs_q_npts))

       call calculate_cumulative_transport_coeff(ph%prefix, 'T', crys%T, 1_i64, 0.0_r64, &
            ph%ens, ph%vels, ph%wvmesh, crys%volume, self%ph_response_T, &
            ph_scalar_mfps, ph_abs_qs, sym, &
            ph_kappa_cumulative_mfp, ph_kappa_cumulative_q, &
            ph_mfp_sampling_grid, ph_q_sampling_grid)

       !  Write scalar cumulative phonon kappa
       call write2file_spectral_tensor('nodrag_iterated_ph_kappa_mfp_cumulative_', ph_kappa_cumulative_mfp)
       call write2file_spectral_tensor('nodrag_iterated_ph_kappa_abs_q_cumulative_', ph_kappa_cumulative_q)
       
       !  Release memory
       deallocate(self%ph_response_T, ph_kappa, dummy, ph_kappa_cumulative_mfp)
    end if

    !Partially decoupled electron BTE
    if(num%drag) then
       call print_message("Partially decoupled electron BTE:")
       call print_message("---------------------")

       !gradT:
       call print_message("gradT field:")

       ! Iterated:
       call print_message(" Calculating iterated electron kappa0 and sigmaS...")

       !  Allocate response function
       allocate(self%el_response_T(el%nwv, el%numbands, 3))

       !  Read response function
       call readfile_response('partdcpl_I0_', self%el_response_T, el%bandlist)

       !  Allocate spectral transport coefficients
       allocate(el_kappa0(el%numbands, 3, 3, num%el_en_num), &
            el_sigmaS(el%numbands, 3, 3, num%el_en_num))

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'T', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_T, el_en_grid, num%tetrahedra, sym, &
            el_kappa0, el_sigmaS)

       !  Write spectral electron kappa
       call write2file_spectral_tensor('partdcpl_iterated_el_kappa0_spectral_', el_kappa0, el%bandlist)

       !  Write spectral electron sigmaS
       call write2file_spectral_tensor('partdcpl_iterated_el_sigmaS_spectral_', el_sigmaS, el%bandlist)

       !  Release memory
       deallocate(self%el_response_T, el_kappa0, el_sigmaS)
       !------------------------------------------------------------------!

       !E:
       call print_message("E field:")

       ! Iterated:
       call print_message(" Calculating iterated electron sigma and alpha/T...")

       !  Allocate response function
       allocate(self%el_response_E(el%nwv, el%numbands, 3))

       !  Read response function
       call readfile_response('partdcpl_J0_', self%el_response_E, el%bandlist)

       !  Allocate spectral transport coefficients
       allocate(el_sigma(el%numbands, 3, 3, num%el_en_num), &
            el_alphabyT(el%numbands, 3, 3, num%el_en_num))
       el_alphabyT = el_alphabyT/crys%T

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'E', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_E, el_en_grid, num%tetrahedra, sym, &
            el_alphabyT, el_sigma)
       el_alphabyT = el_alphabyT/crys%T

       !  Write spectral electron alpha/T
       call write2file_spectral_tensor('partdcpl_iterated_el_alphabyT_spectral_', el_alphabyT, el%bandlist)

       !  Write spectral electron sigma
       call write2file_spectral_tensor('partdcpl_iterated_el_sigma_spectral_', el_sigma, el%bandlist)

       !  Release memory
       deallocate(self%el_response_E, el_alphabyT, el_sigma)
    end if

    !Coupled electron BTE
    if(num%drag) then
       call print_message("Coupled electron BTE:")
       call print_message("---------------------")

       !gradT:
       call print_message("gradT field:")

       ! Iterated:
       call print_message(" Calculating iterated electron kappa0 and sigmaS...")

       !  Allocate response function
       allocate(self%el_response_T(el%nwv, el%numbands, 3))

       !  Read response function
       call readfile_response('drag_I0_', self%el_response_T, el%bandlist)

       !  Allocate spectral transport coefficients
       allocate(el_kappa0(el%numbands, 3, 3, num%el_en_num), &
            el_sigmaS(el%numbands, 3, 3, num%el_en_num))

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'T', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_T, el_en_grid, num%tetrahedra, sym, &
            el_kappa0, el_sigmaS)

       !  Write spectral electron kappa
       call write2file_spectral_tensor('drag_iterated_el_kappa0_spectral_', el_kappa0, el%bandlist)

       !  Write spectral electron sigmaS
       call write2file_spectral_tensor('drag_iterated_el_sigmaS_spectral_', el_sigmaS, el%bandlist)

       !  Release memory
       deallocate(self%el_response_T, el_kappa0, el_sigmaS)
       !------------------------------------------------------------------!

       !E:
       call print_message("E field:")

       ! Iterated:
       call print_message(" Calculating iterated electron sigma and alpha/T...")

       !  Allocate response function
       allocate(self%el_response_E(el%nwv, el%numbands, 3))

       !  Read response function
       call readfile_response('drag_J0_', self%el_response_E, el%bandlist)

       !  Allocate spectral transport coefficients
       allocate(el_sigma(el%numbands, 3, 3, num%el_en_num), &
            el_alphabyT(el%numbands, 3, 3, num%el_en_num))
       el_alphabyT = el_alphabyT/crys%T

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(el, 'E', crys%T, el%spindeg, el%chempot, el%ens, &
            el%vels, crys%volume, self%el_response_E, el_en_grid, num%tetrahedra, sym, &
            el_alphabyT, el_sigma)
       el_alphabyT = el_alphabyT/crys%T

       !  Write spectral electron alpha/T
       call write2file_spectral_tensor('drag_iterated_el_alphabyT_spectral_', el_alphabyT, el%bandlist)

       !  Write spectral electron sigma
       call write2file_spectral_tensor('drag_iterated_el_sigma_spectral_', el_sigma, el%bandlist)

       !  Release memory
       deallocate(self%el_response_E, el_alphabyT, el_sigma)
    end if

    !Coupled phonon BTE
    if(num%drag) then
       call print_message("Coupled phonon BTE:")
       call print_message("---------------------")

       !gradT:
       call print_message("gradT field:")

       ! Iterated:
       call print_message(" Calculating iterated phonon kappa...")

       !  Allocate response function
       allocate(self%ph_response_T(ph%nwv, ph%numbands, 3))

       !  Read response function
       call readfile_response('drag_F0_', self%ph_response_T)

       !  Allocate spectral transport coefficients
       allocate(ph_kappa(ph%numbands, 3, 3, num%ph_en_num), &
            dummy(ph%numbands, 3, 3, num%ph_en_num))

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(ph, 'T', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
            crys%volume, self%ph_response_T, ph_en_grid, num%tetrahedra, sym, ph_kappa, dummy)

       !  Write spectral phonon kappa
       call write2file_spectral_tensor('drag_iterated_ph_kappa_spectral_', ph_kappa)

       !  Release memory
       deallocate(self%ph_response_T, ph_kappa)

       !E:
       call print_message("E field:")

       ! Iterated:
       call print_message(" Calculating iterated phonon alpha/T...")

       !  Allocate response function
       allocate(self%ph_response_E(ph%nwv, ph%numbands, 3))

       !  Read response function
       call readfile_response('drag_G0_', self%ph_response_E)

       !  Allocate spectral transport coefficients
       allocate(ph_alphabyT(ph%numbands, 3, 3, num%ph_en_num))

       !  Calculate spectral function
       call calculate_spectral_transport_coeff(ph, 'E', crys%T, 1_i64, 0.0_r64, ph%ens, ph%vels, &
            crys%volume, self%ph_response_E, ph_en_grid, num%tetrahedra, sym, ph_alphabyT, dummy)
       ph_alphabyT = ph_alphabyT/crys%T

       !  Write spectral phonon kappa
       call write2file_spectral_tensor('drag_iterated_ph_alphabyT_spectral_', ph_alphabyT)

       !  Release memory
       deallocate(self%ph_response_E, ph_alphabyT, dummy)
       !------------------------------------------------------------------!
    end if

    !Return to working directory
    call chdir(trim(adjustl(num%cwd)))

    sync all
  end subroutine post_process
end module bte_module
