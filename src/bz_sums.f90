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

module bz_sums
  !! Module containing the procedures to do Brillouin zone sums.

  use precision, only: r64, i64
  use params, only: kB, qe, pi, hbar_eVps, perm0, twopi, oneI, bohr2nm
  use misc, only: exit_with_message, print_message, write2file_rank2_real, &
       distribute_points, Bose, Fermi, binsearch, mux_vector, twonorm, linspace, &
       write2file_rank1_real
  use screening_module, only: calculate_qTF
  use phonon_module, only: phonon
  use electron_module, only: electron
  use crystal_module, only: crystal
  use numerics_module, only: numerics
  use delta, only: delta_fn, get_delta_fn_pointer
  use symmetry_module, only: symmetry, symmetrize_3x3_tensor, symmetrize_3x3_tensor_noTR
  use Green_function, only: resolvent

  implicit none

  public calculate_dos, calculate_transport_coeff, &
       calculate_el_dos_fermi, calculate_el_Ws, calculate_cumulative_transport_coeff, &
       calculate_el_dos_fermi_gaussian, calculate_el_Ws_gaussian
  private calculate_el_dos, calculate_ph_dos_iso

  interface calculate_dos
     module procedure :: calculate_el_dos, calculate_ph_dos_iso
  end interface calculate_dos
  
contains

  subroutine calculate_el_dos_Fermi_Gaussian(el, reclattvecs)
    !! Calculate spin-normalized electron density of states at the Fermi level
    !! using the adaptive Gaussian broadening method.
    !! Ref: Eq. 18 of Computer Physics Communications 185 (2014) 1747–1758
    !!
    !! el Electron data type

    type(electron), intent(inout) :: el
    real(r64), intent(in) :: reclattvecs(3, 3)

    integer(i64) :: ikp, ibp
    integer :: dim
    real(r64) :: sigma, delta, onebyroot2pi, onebyroot12, aux, Qs(3, 3)

    onebyroot2pi = 1.0_r64/sqrt(twopi)
    onebyroot12 = 1.0_r64/sqrt(12.0_r64)

    do dim = 1, 3
       Qs(dim, :) = reclattvecs(dim, :)/el%wvmesh(dim)
    end do
    
    call print_message("Calculating spin-normalized electronic density of states at Fermi level...")

    el%spinnormed_dos_fermi = 0.0_r64
    do ikp = 1, el%nwv !over FBZ blocks
       do ibp = 1, el%numbands
          !Calculate adaptive smearing
          aux = 0.0_r64
          do dim = 1, 3
             aux = aux + &
                  dot_product(el%vels(ikp, ibp, :), Qs(dim, :))**2
          end do
          sigma = hbar_eVps*onebyroot12*sqrt(aux)
          
          !Evaluate delta[E(iq',ib') - E_Fermi]
          delta = max(onebyroot2pi/sigma*&
               exp(-0.5_r64*((el%chempot - el%ens(ikp, ibp))/sigma)**2), 1.0e-4_r64)

          el%spinnormed_dos_fermi = el%spinnormed_dos_fermi + delta
       end do
    end do
    el%spinnormed_dos_fermi = el%spinnormed_dos_fermi/product(el%wvmesh)

    if(this_image() == 1) then
       write(*, "(A, 1E16.8, A)") ' Spin-normalized DOS(Ef) = ', el%spinnormed_dos_fermi, ' 1/eV/spin'
    end if

    sync all
  end subroutine calculate_el_dos_Fermi_Gaussian
  
  subroutine calculate_el_dos_Fermi(el, usetetra)
    !! Calculate spin-normalized electron density of states at the Fermi level
    !!
    !! el Electron data type
    !! usetetra Use the tetrahedron method for delta functions?
    
    type(electron), intent(inout) :: el
    logical, intent(in) :: usetetra
    
    !Local variables
    integer(i64) :: ikp, ibp
    real(r64) :: delta
    procedure(delta_fn), pointer :: delta_fn_ptr => null()

    call print_message("Calculating spin-normalized electronic density of states at Fermi level...")

    !Associate delta function procedure pointer
    delta_fn_ptr => get_delta_fn_pointer(usetetra)
    
    el%spinnormed_dos_fermi = 0.0_r64
    do ikp = 1, el%nwv !over FBZ blocks
       do ibp = 1, el%numbands
          !Evaluate delta[E(iq',ib') - E_Fermi]
          delta = delta_fn_ptr(el%chempot, ikp, ibp, el%wvmesh, el%simplex_map, &
               el%simplex_count, el%simplex_evals)
          
          el%spinnormed_dos_fermi = el%spinnormed_dos_fermi + delta
       end do
    end do

    if(this_image() == 1) then
       write(*, "(A, 1E16.8, A)") ' Spin-normalized DOS(Ef) = ', el%spinnormed_dos_fermi, ' 1/eV/spin'
    end if

    if(associated(delta_fn_ptr)) nullify(delta_fn_ptr)
    
    sync all
  end subroutine calculate_el_dos_Fermi

  subroutine calculate_el_Ws_Gaussian(el, reclattvecs)
    !! Calculate all electron delta functions scaled by spin-normalized DOS(Ef)
    !! W_mk = delta[E_mk - Ef]/DOS(Ef)
    !
    !Note that here the delta function weights are already supercell normalized. 

    type(electron), intent(inout) :: el
    real(r64), intent(in) :: reclattvecs(3, 3)    
    
    !Local variables
    integer(i64) :: ik_ibz, ik_fbz, ieq, ib
    integer :: dim
    real(r64) :: sigma, delta, onebyroot2pi, onebyroot12, aux, Qs(3, 3)
    
    onebyroot2pi = 1.0_r64/sqrt(twopi)
    onebyroot12 = 1.0_r64/sqrt(12.0_r64)

    do dim = 1, 3
       Qs(dim, :) = reclattvecs(dim, :)/el%wvmesh(dim)
    end do
    
    call print_message("Calculating DOS(Ef) normalized electron delta functions...")

    allocate(el%Ws(el%nwv, el%numbands))
    allocate(el%Ws_irred(el%nwv_irred, el%numbands))

    el%Ws_irred = 0.0_r64
    do ik_ibz = 1, el%nwv_irred
       do ieq = 1, el%nequiv(ik_ibz)
          call binsearch(el%indexlist, el%ibz2fbz_map(ieq, ik_ibz, 2), ik_fbz)
          do ib =1, el%numbands
             !Calculate adaptive smearing
             aux = 0.0_r64
             do dim = 1, 3
                aux = aux + &
                     dot_product(el%vels(ik_fbz, ib, :), Qs(dim, :))**2
             end do
             sigma = hbar_eVps*onebyroot12*sqrt(aux)

             !Evaluate delta[E(iq',ib') - E_Fermi]
             delta = max(onebyroot2pi/sigma*&
                  exp(-0.5_r64*((el%chempot - el%ens(ik_fbz, ib))/sigma)**2), 1.0e-4_r64)

             el%Ws(ik_fbz, ib) = delta
          end do
          el%Ws_irred(ik_ibz, :) = el%Ws_irred(ik_ibz, :) + &
               el%Ws(ik_fbz, :)
       end do
       !Get the irreducible quantities as an average over all FBZ images
       el%Ws_irred(ik_ibz, :) = el%Ws_irred(ik_ibz, :)/el%nequiv(ik_ibz)
    end do
    el%Ws = el%Ws/el%spinnormed_dos_fermi/product(el%wvmesh)
    el%Ws_irred = el%Ws_irred/el%spinnormed_dos_fermi/product(el%wvmesh)
    
    sync all
  end subroutine calculate_el_Ws_Gaussian
  
  subroutine calculate_el_Ws(el, usetetra)
    !! Calculate all electron delta functions scaled by spin-normalized DOS(Ef)
    !! W_mk = delta[E_mk - Ef]/DOS(Ef)
    !
    !Note that here the delta function weights are already supercell normalized. 

    type(electron), intent(inout) :: el
    logical, intent(in) :: usetetra
    
    !Local variables
    integer(i64) :: ik_ibz, ik_fbz, ieq, ib
    real(r64) :: delta
    procedure(delta_fn), pointer :: delta_fn_ptr => null()
    
    call print_message("Calculating DOS(Ef) normalized electron delta functions...")

    !Associate delta function procedure pointer
    delta_fn_ptr => get_delta_fn_pointer(usetetra)
    
    allocate(el%Ws(el%nwv, el%numbands))
    allocate(el%Ws_irred(el%nwv_irred, el%numbands))

    el%Ws_irred = 0.0_r64
    do ik_ibz = 1, el%nwv_irred
       do ieq = 1, el%nequiv(ik_ibz)
          call binsearch(el%indexlist, el%ibz2fbz_map(ieq, ik_ibz, 2), ik_fbz)
          do ib =1, el%numbands
             !Evaluate delta[E(ik,ib) - E_Fermi]
             delta = delta_fn_ptr(el%chempot, ik_fbz, ib, el%wvmesh, el%simplex_map, &
                  el%simplex_count, el%simplex_evals)
             
             el%Ws(ik_fbz, ib) = delta
          end do
          el%Ws_irred(ik_ibz, :) = el%Ws_irred(ik_ibz, :) + &
               el%Ws(ik_fbz, :)
       end do
       !Get the irreducible quantities as an average over all FBZ images
       el%Ws_irred(ik_ibz, :) = el%Ws_irred(ik_ibz, :)/el%nequiv(ik_ibz)
    end do
    el%Ws = el%Ws/el%spinnormed_dos_fermi
    el%Ws_irred = el%Ws_irred/el%spinnormed_dos_fermi

    if(associated(delta_fn_ptr)) nullify(delta_fn_ptr)
    
    sync all
  end subroutine calculate_el_Ws
  
  subroutine calculate_el_dos(el, usetetra)
    !! Calculate the density of states (DOS) in units of 1/energy. 
    !! The DOS will be evaluates on the IBZ mesh energies.
    !!
    !! el Electron data type
    !! usetetra Use the tetrahedron method for delta functions?

    type(electron), intent(inout) :: el
    logical, intent(in) :: usetetra
    
    !Local variables
    integer(i64) :: ik, ib, ikp, ibp, im, chunk, counter, num_active_images
    integer(i64), allocatable :: start[:], end[:]
    real(r64) :: e, delta
    real(r64), allocatable :: dos_chunk(:,:)[:]
    procedure(delta_fn), pointer :: delta_fn_ptr => null()

    call print_message("Calculating electron density of states...")

    !Associate delta function procedure pointer
    delta_fn_ptr => get_delta_fn_pointer(usetetra)
    
    !Allocate start and end coarrays
    allocate(start[*], end[*])
    
    !Divide wave vectors among images
    call distribute_points(el%nwv_irred, chunk, start, end, num_active_images)
    
    !Allocate dos
    allocate(el%dos(el%nwv_irred, el%numbands))

    !Initialize dos array
    el%dos(:,:) = 0.0_r64

    !Allocate small work variable chunk for each image and initialize
    allocate(dos_chunk(chunk, el%numbands)[*])
    dos_chunk(:,:) = 0.0_r64
    
    counter = 0
    !Only work with the active images
    if(this_image() <= num_active_images) then       
       do ik = start, end !Run over IBZ wave vectors
          !Increase counter
          counter = counter + 1
          do ib = 1, el%numbands !Run over wave vectors   
             !Grab sample energy from the IBZ
             e = el%ens_irred(ik, ib) 

             do ikp = 1, el%nwv !Sum over FBZ wave vectors
                do ibp = 1, el%numbands !Sum over wave vectors
                   !Evaluate delta[E(iq,ib) - E(iq',ib')]
                   delta = delta_fn_ptr(e, ikp, ibp, el%wvmesh, el%simplex_map, &
                        el%simplex_count, el%simplex_evals)

                   !Sum over delta function
                   dos_chunk(counter, ib) = dos_chunk(counter, ib) + delta
                end do
             end do
          end do
       end do
       !Multiply with spin degeneracy factor
       dos_chunk(:,:) = el%spindeg*dos_chunk(:,:)
    end if

    if(associated(delta_fn_ptr)) nullify(delta_fn_ptr)
    
    !Gather from images and broadcast to all
    sync all    
    if(this_image() == 1) then
       do im = 1, num_active_images
          el%dos(start[im]:end[im], :) = dos_chunk(:,:)[im]
       end do
    end if
    sync all
    call co_broadcast(el%dos, 1)
    sync all
    
    !Write dos to file
    call write2file_rank2_real(el%prefix // '.dos', el%dos)

    sync all
  end subroutine calculate_el_dos

  subroutine calculate_ph_dos_iso(ph, crys, usetetra,  &
       W_phiso, W_phsubs, phiso, phiso_1B_theory, phsubs, phiso_Tmat)
    !! Calculate the phonon density of states (DOS) in units of 1/energy and,
    !! optionally, the phonon-isotope scattering rates.
    !!
    !! The DOS and isotope scattering rates will be evaluates on the IBZ mesh energies.
    !!
    !! ph Phonon data type
    !! usetetra Use the tetrahedron method for delta functions?

    type(phonon), intent(inout) :: ph
    type(crystal), intent(in) :: crys
    logical, intent(in) :: usetetra, phiso, phsubs, phiso_Tmat
    !real(r64), intent(in) :: gfactors(:), subs_gfactors(:)
    !integer(i64), intent(in) :: atomtypes(:)
    character(len = 6), intent(in) :: phiso_1B_theory
    real(r64), intent(out), allocatable :: W_phiso(:,:), W_phsubs(:,:)
    
    !Local variables
    integer(i64) :: iq, ib, iqp, ibp, im, chunk, counter, num_active_images, &
         pol, a, numatoms
    integer(i64), allocatable :: start[:], end[:]
    real(r64) :: e, delta, aux, matel_iso, matel_subs
    real(r64), allocatable :: dos_chunk(:,:)[:], W_phiso_chunk(:,:)[:], &
         W_phsubs_chunk(:,:)[:]
    procedure(delta_fn), pointer :: delta_fn_ptr => null()
    
    call print_message("Calculating phonon density of states and (if needed) isotope/substitution scattering...")

    !Associate delta function procedure pointer
    delta_fn_ptr => get_delta_fn_pointer(usetetra)

    !Number of basis atoms
    numatoms = size(crys%atomtypes)
    
    !Allocate start and end coarrays
    allocate(start[*], end[*])
    
    !Divide wave vectors among images
    call distribute_points(ph%nwv_irred, chunk, start, end, num_active_images)
        
    !Allocate dos and W_phiso
    allocate(ph%dos(ph%nwv_irred, ph%numbands))
    allocate(W_phiso(ph%nwv_irred, ph%numbands))
    allocate(W_phsubs(ph%nwv_irred, ph%numbands))

    !Initialize arrays and coarrays
    ph%dos(:,:) = 0.0_r64
    W_phiso(:,:) = 0.0_r64
    W_phsubs(:,:) = 0.0_r64

    !!Initialize the matrix elements storage
    if (phiso .and. .not. phiso_Tmat) then 
      call ph%xiso%allocate_xmassvar(ph, usetetra, phiso_Tmat)
    end if 
    if (phsubs) then
      call ph%xsubs%allocate_xmassvar(ph, usetetra, phiso_Tmat)
    end if
    
    !Allocate small work variable chunk for each image
    allocate(dos_chunk(chunk, ph%numbands)[*])
    if(phiso .and. .not. phiso_Tmat) allocate(W_phiso_chunk(chunk, ph%numbands)[*])
    if(phsubs) allocate(W_phsubs_chunk(chunk, ph%numbands)[*])
    dos_chunk(:,:) = 0.0_r64
    if(phiso .and. .not. phiso_Tmat) W_phiso_chunk(:,:) = 0.0_r64
    if(phsubs) W_phsubs_chunk(:,:) = 0.0_r64
    
    counter = 0
    !Only work with the active images
    if(this_image() <= num_active_images) then       
       do iq = start, end !Run over IBZ wave vectors
          !Increase counter
          counter = counter + 1
          do ib = 1, ph%numbands !Run over wave vectors   
             !Grab sample energy from the IBZ
             e = ph%ens(ph%indexlist_irred(iq), ib) 

             do iqp = 1, ph%nwv !Sum over FBZ wave vectors
                do ibp = 1, ph%numbands !Sum over wave vectors
                   !Evaluate delta[E(iq,ib) - E(iq',ib')]
                   delta = delta_fn_ptr(e, iqp, ibp, ph%wvmesh, ph%simplex_map, &
                        ph%simplex_count, ph%simplex_evals)

                   ! If not energy conserving ignore
                   if (delta <= 0.0_r64 ) then
                     cycle
                   end if

                   !Sum over delta function
                   dos_chunk(counter, ib) = dos_chunk(counter, ib) + delta

                   matel_iso = 0.0_r64
                   matel_subs = 0.0_r64
                   if((phiso .and. .not. phiso_Tmat) .or. phsubs) then
                      do a = 1, numatoms
                         pol = (a - 1)*3
                         aux = (abs(dot_product(&
                              ph%evecs(ph%indexlist_irred(iq), ib, pol + 1 : pol + 3), &
                              ph%evecs(iqp, ibp, pol + 1 : pol + 3))))**2

                         !Calculate phonon-isotope scattering in the Tamura model                   
                         if(phiso .and. .not. phiso_Tmat) then
                            if(phiso_1B_theory == 'DIB-1B') then !DIB 1st Born
                               matel_iso = matel_iso + &
                                    delta*aux*crys%gfactors_DIB(crys%atomtypes(a))*e**2
                            else !Tamura (= VCA 1st Born)
                               matel_iso = matel_iso + &
                                    delta*aux*crys%gfactors_VCA(crys%atomtypes(a))*e**2
                            end if
                         end if

                         !Calculate phonon-substitution scattering in the Tamura model
                         if(phsubs) then
                            matel_subs = matel_subs + &
                                 delta*aux*crys%subs_gfactors(crys%atomtypes(a))*e**2
                         end if
                      end do
                   end if
                   ! Save here
                   if (phiso .and. .not. phiso_Tmat) then
                     W_phiso_chunk(counter, ib) = W_phiso_chunk(counter, ib) +  & 
                              matel_iso * 0.5_r64 * pi / hbar_eVps
                     call ph%xiso%save_xmassvar(ph%numbands, iq, iqp, ib, ibp, matel_iso)
                   end if
                   if (phsubs) then
                     W_phsubs_chunk(counter, ib) = W_phsubs_chunk(counter, ib) +  & 
                              matel_subs * 0.5_r64 * pi / hbar_eVps
                     call ph%xsubs%save_xmassvar(ph%numbands, iq, iqp, ib, ibp, matel_subs)
                   end if  
                end do
             end do
          end do
       end do
    end if

    if(associated(delta_fn_ptr)) nullify(delta_fn_ptr)
    
    !Gather from images and broadcast to all
    sync all
    if(this_image() == 1) then
       do im = 1, num_active_images
          ph%dos(start[im]:end[im], :) = dos_chunk(:,:)[im]
          if(phiso .and. .not. phiso_Tmat) &
               W_phiso(start[im]:end[im], :) = W_phiso_chunk(:,:)[im]
          if(phsubs) W_phsubs(start[im]:end[im], :) = W_phsubs_chunk(:,:)[im]
       end do
    end if
    sync all
    call co_broadcast(ph%dos, 1)
    call co_broadcast(W_phiso, 1)
    call co_broadcast(W_phsubs, 1)
    sync all
    
    !Write to file
    call write2file_rank2_real(ph%prefix // '.dos', ph%dos)
    call write2file_rank2_real(ph%prefix // '.W_rta_phiso', W_phiso)
    call write2file_rank2_real(ph%prefix // '.W_rta_phsubs', W_phsubs)

    sync all
  end subroutine calculate_ph_dos_iso

  subroutine calculate_transport_coeff(species_prefix, field, T, deg, chempot, ens, vels, &
       volume, mesh, response, sym, trans_coeff_hc, trans_coeff_cc, Bfield, symmetrize)
    !! Subroutine to calculate transport coefficients.
    !!
    !! species_prefix Prefix of particle type
    !! field Type of field
    !! T Temperature in K
    !! deg Degeneracy
    !! chempot Chemical potential in eV
    !! ens FBZ energies in eV
    !! vels FBZ velocities in Km/s
    !! volume Primitive cell volume in nm^3
    !! mesh Wave vector grid
    !! response FBZ response function
    !! sym Symmery object
    !! trans_coeff_hc Heat current coefficient
    !! trans_coeff_cc Charge current coefficient

    character(len = 2), intent(in) :: species_prefix
    character(len = 1), intent(in) :: field
    integer(i64), intent(in) :: mesh(3), deg
    real(r64), intent(in) :: T, chempot, ens(:,:), vels(:,:,:), volume, response(:,:,:)
    type(symmetry), intent(in) :: sym
    real(r64), optional, intent(in) :: Bfield(3)
    logical, optional, intent(in)   :: symmetrize
    real(r64), intent(out) :: trans_coeff_hc(:,:,:), trans_coeff_cc(:,:,:)
    ! Above, h(c)c = heat(charge) current
    
    !Local variables
    integer(i64) :: ik, ib, j, l, nk, nbands, pow_hc, pow_cc
    real(r64) :: dist_factor, e, v, fac, A_hc, A_cc
    logical :: symmetrize_local = .true.

    if (present(symmetrize)) symmetrize_local = symmetrize
    
    nk = size(ens(:,1))
    nbands = size(ens(1,:))

    !Common multiplicative factor
    fac = 1.0e21/kB/T/volume/product(mesh) 
    
    !Do checks related to particle and field type
    if(species_prefix == 'ph') then
       if(chempot /= 0.0_r64) then
          call exit_with_message(&
               "Phonon chemical potential non-zero in calculate_transport_coefficient. Exiting.")
       end if
       if(field == 'T') then
          A_hc = qe*fac
          pow_hc = 1
          A_cc = 0.0_r64
          pow_cc = 0
       else if(field == 'E') then
          A_hc = -fac
          pow_hc = 1
          A_cc = 0.0_r64
          pow_cc = 0
       else
          call exit_with_message("Unknown field type in calculate_transport_coefficient. Exiting.")
       end if
    else if(species_prefix == 'el') then       
       if(field == 'T') then
          A_cc = -deg*qe*fac
          pow_cc = 0
          A_hc = deg*qe*fac
          pow_hc = 1
       else if(field == 'E') then
          A_cc = deg*fac
          pow_cc = 0
          A_hc = -A_cc
          pow_hc = 1
       else
          call exit_with_message("Unknown field type in calculate_transport_coefficient. Exiting.")
       end if
    else
       call exit_with_message("Unknown particle species in calculate_transport_coefficient. Exiting.")
    end if
    
    trans_coeff_hc = 0.0_r64
    trans_coeff_cc = 0.0_r64

    do ik = 1, nk
       do ib = 1, nbands
          e = ens(ik, ib)
          if(species_prefix == 'ph') then
             if(e == 0.0_r64) cycle !Ignore zero energies phonons
             dist_factor = Bose(e, T)
             dist_factor = dist_factor*(1.0_r64 + dist_factor)
          else
             dist_factor = Fermi(e, chempot, T)
             dist_factor = dist_factor*(1.0_r64 - dist_factor)
          end if
          do j = 1, size(trans_coeff_hc,2)
             v = vels(ik, ib, j)
             trans_coeff_hc(ib, j, :) = trans_coeff_hc(ib, j, :) + &
                  (e - chempot)**pow_hc*dist_factor*v*response(ik, ib, :)
             if(A_cc /= 0.0_r64) then
                trans_coeff_cc(ib, j, :) = trans_coeff_cc(ib, j, :) + &
                     (e - chempot)**pow_cc*dist_factor*v*response(ik, ib, :)
             end if
          end do
       end do
    end do
    !Units:
    ! W/m/K for thermal conductivity
    ! 1/Omega/m for charge conductivity
    ! V/K for thermopower
    ! A/m for alpha
    trans_coeff_hc = A_hc*trans_coeff_hc
    if(A_cc /= 0.0_r64) trans_coeff_cc = A_cc*trans_coeff_cc

    !TODO The following has to be generalized in the presence of a B-field
    !Symmetrize transport tensor
    if (symmetrize_local) then
      do ib = 1, nbands
         !Note that fortran does not short-circuit logical expression chains
         if(present(Bfield)) then
            if(any(Bfield /= 0.0_r64)) then
               call symmetrize_3x3_tensor_noTR(trans_coeff_hc(ib, :, :), sym%crotations, Bfield)
               if(A_cc /= 0.0_r64) call symmetrize_3x3_tensor_noTR(trans_coeff_cc(ib, :, :), sym%crotations, Bfield)
            end if
         else
            call symmetrize_3x3_tensor(trans_coeff_hc(ib, :, :), sym%crotations)
            if(A_cc /= 0.0_r64) call symmetrize_3x3_tensor(trans_coeff_cc(ib, :, :), sym%crotations)
         end if
      end do
    end if
  end subroutine calculate_transport_coeff
  
  subroutine calculate_spectral_transport_coeff(species, field, T, deg, chempot, &
       ens, vels, volume, response, en_grid, usetetra, sym, trans_coeff_hc, trans_coeff_cc)
    !! Subroutine to calculate the spectral transport coefficients.
    !!
    !! species Object of species type
    !! field Type of field
    !! T Temperature in K
    !! deg Degeneracy
    !! chempot Chemical potential in eV
    !! ens FBZ energies in eV
    !! vels FBZ velocities in Km/s
    !! volume Primitive cell volume in nm^3
    !! usetetra Use tetrahedron method?
    !! sym Symmery object
    !! trans_coeff_hc Heat current coefficient
    !! trans_coeff_cc Charge current coefficient

    class(*), intent(in) :: species
    character(len = 1), intent(in) :: field
    integer(i64), intent(in) :: deg
    real(r64), intent(in) :: T, chempot, ens(:,:), vels(:,:,:), volume, &
         response(:,:,:), en_grid(:)
    logical, intent(in) :: usetetra
    type(symmetry), intent(in) :: sym
    real(r64), intent(out) :: trans_coeff_hc(:,:,:,:), trans_coeff_cc(:,:,:,:)

    !Local variables
    character(len = 2) :: species_prefix
    ! Above, h(c)c = heat(charge) current
    integer(i64) :: ik, ib, ie, icart, nk, nbands, ne, pow_hc, pow_cc
    real(r64) :: dist_factor, e, v, fac, A_hc, A_cc, delta
    procedure(delta_fn), pointer :: delta_fn_ptr => null()

    !Associate delta function procedure pointer
    delta_fn_ptr => get_delta_fn_pointer(usetetra)
    
    nk = size(ens(:,1)) !Number of (transport active) wave vectors
    nbands = size(ens(1,:)) !Number of bands/branches
    ne = size(en_grid(:)) !Number of sampling energy mesh points    

    !Common multiplicative factor
    fac = 1.0e21/kB/T/volume

    !Grab species prefix
    select type(species)
    class is(phonon)
       species_prefix = species%prefix
    class is(electron)
       species_prefix = species%prefix
    class default
       species_prefix = 'xx' !Unknown species
    end select
    
    !Do checks related to particle and field type
    if(species_prefix == 'ph') then
       if(chempot /= 0.0_r64) then
          call exit_with_message(&
               "Phonon chemical potential non-zero in calculate_transport_coefficient. Exiting.")
       end if
       if(field == 'T') then
          A_hc = qe*fac
          pow_hc = 1
          A_cc = 0.0_r64
          pow_cc = 0
       else if(field == 'E') then
          A_hc = -fac
          pow_hc = 1
          A_cc = 0.0_r64
          pow_cc = 0
       else
          call exit_with_message("Unknown field type in calculate_transport_coefficient. Exiting.")
       end if
    else if(species_prefix == 'el') then       
       if(field == 'T') then
          A_cc = -deg*qe*fac
          pow_cc = 0
          A_hc = deg*qe*fac
          pow_hc = 1
       else if(field == 'E') then
          A_cc = deg*fac
          pow_cc = 0
          A_hc = -A_cc
          pow_hc = 1
       else
          call exit_with_message(&
               "Unknown field type in calculate_spectral_transport_coefficient. Exiting.")
       end if
    else
       call exit_with_message(&
            "Unknown particle species in calculate_spectral_transport_coefficient. Exiting.")
    end if

    !Initialize transport coefficients
    trans_coeff_hc = 0.0_r64
    trans_coeff_cc = 0.0_r64
    
    do ik = 1, nk !Sum over wave vectors
       do ib = 1, nbands !Sum over bands/branches
          e = ens(ik, ib) !Grab energy

          !Calculate distribution function factor
          if(species_prefix == 'ph') then
             if(e == 0.0_r64) cycle !Ignore zero energies phonons
             dist_factor = Bose(e, T)
             dist_factor = dist_factor*(1.0_r64 + dist_factor)
          else
             dist_factor = Fermi(e, chempot, T)
             dist_factor = dist_factor*(1.0_r64 - dist_factor)
          end if
          
          !Run over sampling energies
          do ie = 1, ne
             !Evaluate delta function
             select type(species)
             class is(phonon)
                delta = delta_fn_ptr(en_grid(ie), ik, ib, species%wvmesh, species%simplex_map, &
                     species%simplex_count, species%simplex_evals)
             class is(electron)
                delta = delta_fn_ptr(en_grid(ie), ik, ib, species%wvmesh, species%simplex_map, &
                     species%simplex_count, species%simplex_evals)
             end select
             
             do icart = 1, 3 !Run over Cartesian directions
                v = vels(ik, ib, icart) !Grab velocity
                trans_coeff_hc(ib, icart, :, ie) = trans_coeff_hc(ib, icart, :, ie) + &
                     (en_grid(ie) - chempot)**pow_hc*dist_factor*v*response(ik, ib, :)*delta
                if(A_cc /= 0.0_r64) then
                   trans_coeff_cc(ib, icart, :, ie) = trans_coeff_cc(ib, icart, :, ie) + &
                        (en_grid(ie) - chempot)**pow_cc*dist_factor*v*response(ik, ib, :)*delta
                end if
             end do
          end do !ie
       end do !ib
    end do !ik
    !Units:
    ! W/m/K/eV for spectral thermal conductivity
    ! 1/Omega/m/eV for spectral charge conductivity
    ! V/K/eV for spectral thermopower
    ! A/m/eV for spectral alpha
    trans_coeff_hc = A_hc*trans_coeff_hc
    if(A_cc /= 0.0_r64) trans_coeff_cc = A_cc*trans_coeff_cc

    !Symmetrize transport tensor
    do ie = 1, ne
       do ib = 1, nbands
          call symmetrize_3x3_tensor(trans_coeff_hc(ib, :, :, ie), sym%crotations)
          if(A_cc /= 0.0_r64) call symmetrize_3x3_tensor(trans_coeff_cc(ib, :, :, ie), sym%crotations)
       end do
    end do

    if(associated(delta_fn_ptr)) nullify(delta_fn_ptr)
  end subroutine calculate_spectral_transport_coeff

!!$  subroutine calculate_mfp_cumulative_transport_coeff(species_prefix, field, T, deg, chempot, &
!!$       ens, vels, mesh, volume, response, mfp_grid_sampling, mfps, sym, trans_coeff_hc)!, trans_coeff_cc)
  subroutine calculate_cumulative_transport_coeff(species_prefix, field, T, deg, chempot, &
       ens, vels, mesh, volume, response, mfps, abs_qs, sym, &
       trans_coeff_hc_mfp, trans_coeff_hc_q, &
       mfp_grid_sampling, q_grid_sampling)
    !! Subroutine to calculate the mean-free-path and |q| cumulative transport coefficients.
    !!
    !! species_prefix Prefix of particle type
    !! field Type of field
    !! T Temperature in K
    !! deg Degeneracy
    !! chempot Chemical potential in eV
    !! ens FBZ energies in eV
    !! vels FBZ velocities in Km/s
    !! volume Primitive cell volume in nm^3
    !! mesh Wave vector mesh
    !! response Response function (units depend of the specieas and the field type)
    !! mfps Mode resolved mean-free-path
    !! abs_qs Absolute values of FBZ wave vectors
    !! sym Symmery object
    !! trans_coeff_hc Heat current coefficient
    !! trans_coeff_cc Charge current coefficient
    !! mfp_grid_sampling Scalar mean-free-path sampling grid
    !! q_grid_sampling |q| sampling grid

    character(len = 2), intent(in) :: species_prefix
    character(len = 1), intent(in) :: field    
    integer(i64), intent(in) :: deg, mesh(3)
    real(r64), intent(in) :: T, chempot, ens(:,:), mfps(:, :), abs_qs(:), &
         vels(:,:,:), volume, response(:,:,:), mfp_grid_sampling(:), q_grid_sampling(:)
    type(symmetry), intent(in) :: sym
    real(r64), intent(out) :: trans_coeff_hc_mfp(:,:,:,:), trans_coeff_hc_q(:,:,:,:)

    !Local variables
    ! Above, h(c)c = heat(charge) current
    integer(i64) :: ik, iq_sampling, ib, imfp, icart, nmfp, nk, nbands, pow_hc!, pow_cc
    real(r64) :: dist_factor, e, v, fac, A_hc!, A_cc
    
    nk = size(ens(:,1))
    nbands = size(ens(1,:))
    nmfp = size(mfp_grid_sampling)

    !Common multiplicative factor
    fac = 1.0e21/kB/T/volume/product(mesh) 

    !Do checks related to particle and field type
    if(species_prefix == 'ph') then
       if(chempot /= 0.0_r64) then
          call exit_with_message(&
               "Phonon chemical potential non-zero in calculate_mfp_cumulative_transport_coeff. Exiting.")
       end if
       if(field == 'T') then
          A_hc = qe*fac
          pow_hc = 1
!!$          A_cc = 0.0_r64
!!$          pow_cc = 0
       else if(field == 'E') then
!!$          A_hc = -fac
!!$          pow_hc = 1
!!$          A_cc = 0.0_r64
!!$          pow_cc = 0
          call exit_with_message("Not supported yet. Exiting.")
       else
          call exit_with_message("Unknown field type in calculate_mfp_cumulative_transport_coeff. Exiting.")
       end if
    else if(species_prefix == 'el') then       
!!$       if(field == 'T') then
!!$          A_cc = -deg*qe*fac
!!$          pow_cc = 0
!!$          A_hc = deg*qe*fac
!!$          pow_hc = 1
!!$       else if(field == 'E') then
!!$          A_cc = deg*fac
!!$          pow_cc = 0
!!$          A_hc = -A_cc
!!$          pow_hc = 1
!!$       else
!!$          call exit_with_message("Unknown field type in calculate_mfp_cumulative_transport_coeff. Exiting.")
!!$       end if
       call exit_with_message("Not supported yet. Exiting.")
    else
       call exit_with_message("Unknown particle species in calculate_mfp_cumulative_transport_coeff. Exiting.")
    end if

    trans_coeff_hc_mfp = 0.0_r64
    do imfp = 1, nmfp
       do ik = 1, nk
          do ib = 1, nbands
             !Theta(mfp(ik, ib) - mfp_sampling) condition
             if(mfps(ik, ib) <= mfp_grid_sampling(imfp)) then

                e = ens(ik, ib)
                if(species_prefix == 'ph') then
                   if(e == 0.0_r64) cycle !Ignore zero energy phonons
                   dist_factor = Bose(e, T)
                   dist_factor = dist_factor*(1.0_r64 + dist_factor)
                else
!!$             dist_factor = Fermi(e, chempot, T)
!!$             dist_factor = dist_factor*(1.0_r64 - dist_factor)
                   call exit_with_message("Not supported yet. Exiting.")
                end if
                do icart = 1, 3
                   v = vels(ik, ib, icart)
                   trans_coeff_hc_mfp(ib, icart, :, imfp) = trans_coeff_hc_mfp(ib, icart, :, imfp) + &
                        (e - chempot)**pow_hc*dist_factor*v*response(ik, ib, :)
!!$                if(A_cc /= 0.0_r64) then
                   !TODO
!!$                end if
                end do
             end if
          end do
       end do
    end do

    trans_coeff_hc_q = 0.0_r64
    do iq_sampling = 1, size(q_grid_sampling)
       do ik = 1, nk
          !Theta(|q| - |q|_sampling) condition
          if(abs_qs(ik) <= q_grid_sampling(iq_sampling)) then
             do ib = 1, nbands
                e = ens(ik, ib)
                if(species_prefix == 'ph') then
                   if(e == 0.0_r64) cycle !Ignore zero energy phonons
                   dist_factor = Bose(e, T)
                   dist_factor = dist_factor*(1.0_r64 + dist_factor)
                else
!!$             dist_factor = Fermi(e, chempot, T)
!!$             dist_factor = dist_factor*(1.0_r64 - dist_factor)
                   call exit_with_message("Not supported yet. Exiting.")
                end if
                do icart = 1, 3
                   v = vels(ik, ib, icart)
                   trans_coeff_hc_q(ib, icart, :, iq_sampling) = &
                        trans_coeff_hc_q(ib, icart, :, iq_sampling) + &
                        (e - chempot)**pow_hc*dist_factor*v*response(ik, ib, :)
!!$                if(A_cc /= 0.0_r64) then
                   !TODO
!!$                end if
                end do
             end do
          end if
       end do
    end do
    
    !Units:
    ! W/m/K for thermal conductivity
    ! 1/Omega/m for charge conductivity
    ! V/K for thermopower
    ! A/m/K for alpha/T
    trans_coeff_hc_mfp = A_hc*trans_coeff_hc_mfp
    trans_coeff_hc_q = A_hc*trans_coeff_hc_q
!!$    if(A_cc /= 0.0_r64) trans_coeff_cc = A_cc*trans_coeff_cc

    !Symmetrize transport tensor
    do imfp = 1, nmfp
       do ib = 1, nbands
          call symmetrize_3x3_tensor(trans_coeff_hc_mfp(ib, :, :, imfp), sym%crotations)
!!$          if(A_cc /= 0.0_r64) call symmetrize_3x3_tensor(trans_coeff_cc(ib, :, :, imfp), sym%crotations)
       end do
    end do
    
    !Symmetrize transport tensor
    do iq_sampling = 1, size(q_grid_sampling)
       do ib = 1, nbands
          call symmetrize_3x3_tensor(trans_coeff_hc_q(ib, :, :, iq_sampling), sym%crotations)
       end do
    end do
  end subroutine calculate_cumulative_transport_coeff
end module bz_sums
