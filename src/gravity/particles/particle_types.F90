!
! PIERNIK Code Copyright (C) 2006 Michal Hanasz
!
!    This file is part of PIERNIK code.
!
!    PIERNIK is free software: you can redistribute it and/or modify
!    it under the terms of the GNU General Public License as published by
!    the Free Software Foundation, either version 3 of the License, or
!    (at your option) any later version.
!
!    PIERNIK is distributed in the hope that it will be useful,
!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!    GNU General Public License for more details.
!
!    You should have received a copy of the GNU General Public License
!    along with PIERNIK.  If not, see <http://www.gnu.org/licenses/>.
!
!    Initial implementation of PIERNIK code was based on TVD split MHD code by
!    Ue-Li Pen
!        see: Pen, Arras & Wong (2003) for algorithm and
!             http://www.cita.utoronto.ca/~pen/MHD
!             for original source code "mhd.f90"
!
!    For full list of developers see $PIERNIK_HOME/license/pdt.txt
!
#include "piernik.h"

!>  \brief Types for selfgravitating particles

module particle_types
! pulled by GRAV
   use constants, only: ndims

   implicit none

   private
   public :: particle_set, particle_solver_T

   !>
   !! \brief simple particle: just mass and position
   !!
   !! \todo Extend it a bit
   !<
   type :: particle
      real                   :: mass       !< mass of the particle
      real, dimension(ndims) :: pos        !< physical position
      real, dimension(ndims) :: vel        !< particle velocity
      logical                :: outside    !< this flag is true if the particle is outside the domain
   contains
      procedure :: is_outside              !< compute the outside flag
   end type particle

   !> \brief A list of particles and some associated methods

   type :: particle_set
      type(particle), allocatable, dimension(:) :: p !< the list of particles
      procedure(map_scheme), pointer :: map
   contains
      procedure :: init        !< initialize the list
      procedure :: print       !< print the list
      procedure :: cleanup     !< delete the list
      procedure :: remove      !< remove a particle
      procedure :: merge_parts !< merge two particles
      procedure :: set_map
      procedure :: map_ngp     !< project particles onto grid
      procedure :: map_cic     !< project particles onto grid
      procedure :: map_tsc     !< project particles onto grid
      procedure :: evolve => particle_set_evolve !< perform time integration with n-body solver
      procedure :: add_using_basic_types   !< add a particle
      procedure :: add_using_derived_type  !< add a particle
      procedure :: particle_with_id_exists  !< Check if particle no. "i" exists
      generic, public :: exists => particle_with_id_exists
      generic, public :: add => add_using_basic_types, add_using_derived_type
   end type particle_set

   type, abstract :: particle_solver_T
      ! additional data goes here in extended types
      ! evolve need to have "pass" keyword to access them
   contains
      procedure(particle_solver_P), nopass, deferred :: evolve
   end type particle_solver_T

   abstract interface
      subroutine particle_solver_P(pset, t_glob, dt_tot)
         import :: particle_set
         class(particle_set), intent(inout) :: pset
         real, intent(in) :: t_glob, dt_tot
      end subroutine particle_solver_P

      subroutine map_scheme(this, iv, factor)
         import :: particle_set
         implicit none
         class(particle_set), intent(in)    :: this   !< an object invoking the type-bound procedure
         integer(kind=4),     intent(in)    :: iv     !< index in cg%q array, where we want the particles to be projected
         real,                intent(in)    :: factor !< typically fpiG
      end subroutine map_scheme
   end interface

   type(particle_set), target :: pset !< default particle list

contains

!> \brief compute the outside flag

   subroutine is_outside(this)

      use constants, only: LO, HI
      use domain,    only: dom

      implicit none

      class(particle), intent(inout) :: this     !< an object invoking the type-bound procedure

      this%outside = any(dom%has_dir(:) .and. (this%pos(:) < dom%edge(:, LO) .or. this%pos(:) >= dom%edge(:, HI)))
      ! Inequalities above must match the rounding function used in map routine (floor() includes bottom edge, but excludes top edge)

   end subroutine is_outside

!> \brief initialize the list with 0 elements

   subroutine init(this)

      use dataio_pub, only: die

      implicit none

      class(particle_set), intent(inout) :: this     !< an object invoking the type-bound procedure

      if (allocated(this%p)) call die("[particle_types:init] already initialized")
      allocate(this%p(0))

   end subroutine init

!> \brief print the list

   subroutine print(this)

      use dataio_pub, only: msg, printinfo
      use mpisetup,   only: slave

      implicit none

      class(particle_set), intent(inout) :: this     !< an object invoking the type-bound procedure

      integer :: i

      !> \ todo communicate particles that aren't known to the master
      if (slave) return

      if (size(this%p) <= 0) return

      call printinfo("[particle_types:print] Known particles:")
      write(msg, '(a,a12,2(a,a36),2a)')" #number   : ","mass"," [ ","position"," ] [ ","velocity"," ]  is_outside"
      call printinfo(msg)
      do i = lbound(this%p, dim=1), ubound(this%p, dim=1)
         write(msg, '(a,i7,a,g12.3,2(a,3g12.3),a,l2)')" # ",i," : ",this%p(i)%mass," [ ",this%p(i)%pos," ] [ ",this%p(i)%vel," ] ",this%p(i)%outside
         call printinfo(msg)
      enddo

   end subroutine print

!> \brief delete the list

   subroutine cleanup(this)

      implicit none

      class(particle_set), intent(inout) :: this     !< an object invoking the type-bound procedure

      if (allocated(this%p)) deallocate(this%p)

    end subroutine cleanup

!> \brief Add a particle to the list

   subroutine add_using_derived_type(this, part)

      implicit none

      class(particle_set), intent(inout) :: this     !< an object invoking the type-bound procedure
      type(particle),      intent(in)    :: part     !< new particle

! Cannot just do "call part%is_outside" because this will require changes of intent here and in add_using_basic_types, which we don\'t want to do
      this%p = [this%p, part]  ! LHS-realloc
      call this%p(ubound(this%p, dim=1))%is_outside

   end subroutine add_using_derived_type

!> \brief Add a particle to the list

   subroutine add_using_basic_types(this, mass, pos, vel)

      implicit none

      class(particle_set),    intent(inout) :: this     !< an object invoking the type-bound procedure
      real,                   intent(in)    :: mass     !< mass of the particle (negative values are allowed just in case someone wants to calculate electric potential)
      real, dimension(:), intent(in)    :: pos      !< physical position
      real, dimension(:), intent(in)    :: vel      !< particle velosity

      call this%add(particle(mass, pos, vel, .false.))

   end subroutine add_using_basic_types

!> \brief Remove a partilce number id from the list

   subroutine remove(this, id)

      use dataio_pub, only: msg, die

      implicit none

      class(particle_set), intent(inout) :: this !< an object invoking the type-bound procedure
      integer,             intent(in)    :: id   !< position in the array of particles

      if (.not. this%exists(id)) then
         write(msg, '("[particle_types:remove] Particle no Id = ",I6," does not exist")') id
         call die(msg)
      endif

      this%p = [this%p(:id-1), this%p(id+1:)]   ! LHS-realloc, please note  that if id == lbound(this%p, 1)
                                                ! or id == ubound(this%p, 1) it does not cause out of bound
                                                ! access in p
   end subroutine remove

!>
!! \brief Merge two particles
!!
!! \todo consider implementation as overloading of the (+) operator
!<

   subroutine merge_parts(this, id1, id2)

      implicit none

      class(particle_set), intent(inout) :: this !< an object invoking the type-bound procedure
      integer,             intent(in)    :: id1  !< position of the first particle in the array of particles (particle to be replaced by the merger)
      integer,             intent(in)    :: id2  !< position of the second partilce in the array of particles (particle to be removed)

      type(particle) :: merger

      merger%mass = this%p(id1)%mass + this%p(id2)%mass
      merger%pos  = (this%p(id1)%mass*this%p(id1)%pos + this%p(id2)%mass*this%p(id2)%pos) / merger%mass ! CoM

      this%p(id1) = merger
      call this%p(id1)%is_outside
      call this%remove(id2)

   end subroutine merge_parts

!>
!! \brief Set function that projects particles onto grid
!<

   subroutine set_map(this, ischeme)
      use constants,    only: I_NGP, I_CIC, I_TSC
      use dataio_pub,   only: die

      implicit none
      class(particle_set), intent(inout) :: this    !< an object invoking the type-bound procedure
      integer(kind=4),     intent(in)    :: ischeme !< index of interpolation scheme

      select case (ischeme)
         case (I_NGP)
            this%map => map_ngp
         case (I_CIC)
            this%map => map_cic
         case (I_TSC)
            this%map => map_tsc
         case default
            call die("[particle_types:set] Interpolation scheme selector's logic in particle_pub:init_particles is broken. Go fix it!")
      end select
   end subroutine set_map

!>
!! \brief Project the particles onto density map
!!
!! \details With the help of multigrid self-gravity solver the gravitational potential of the particle set can be found
!!
!! \warning Current implementation of the multipole solver isn't aware of particles, co if any of them exist outside of the domain, their potential will be ignored.
!! \todo Fix the multipole solver
!!
!! \todo Add an option for less compact mapping that nullifies self-forces
!!
!! \warning Particles outside periodic domain are ignored
!<

   subroutine map_ngp(this, iv, factor)

      use cg_leaves,  only: leaves
      use cg_list,    only: cg_list_element
      use constants,  only: xdim, ydim, zdim, ndims, LO, HI, GEO_XYZ
      use dataio_pub, only: die
      use domain,     only: dom

      implicit none

      class(particle_set), intent(in)    :: this   !< an object invoking the type-bound procedure
      integer(kind=4),     intent(in)    :: iv     !< index in cg%q array, where we want the particles to be projected
      real,                intent(in)    :: factor !< typically fpiG

      type(cg_list_element), pointer :: cgl
      integer :: p
      integer(kind=8), dimension(ndims) :: ijkp

      cgl => leaves%first
      do while (associated(cgl))

         ijkp(:) = cgl%cg%ijkse(:,LO)
         do p = lbound(this%p, dim=1), ubound(this%p, dim=1)
            if (dom%geometry_type /= GEO_XYZ) call die("[particle_types:map_ngp] Unsupported geometry")
            where (dom%has_dir(:)) ijkp(:) = floor((this%p(p)%pos(:)-cgl%cg%fbnd(:, LO))/cgl%cg%dl(:)) + cgl%cg%ijkse(:, LO)
            if (all(ijkp >= cgl%cg%ijkse(:,LO)) .and. all(ijkp <= cgl%cg%ijkse(:,HI))) &
                 cgl%cg%q(iv)%arr(ijkp(xdim), ijkp(ydim), ijkp(zdim)) = cgl%cg%q(iv)%arr(ijkp(xdim), ijkp(ydim), ijkp(zdim)) + factor * this%p(p)%mass / cgl%cg%dvol
         enddo

         cgl => cgl%nxt
      enddo

   end subroutine map_ngp

   subroutine map_cic(this, iv, factor)

      use cg_leaves, only: leaves
      use cg_list,   only: cg_list_element
      use constants, only: xdim, ydim, zdim, ndims, LO, HI, CENTER
      use domain,    only: dom

      implicit none

      class(particle_set), intent(in)    :: this   !< an object invoking the type-bound procedure
      integer(kind=4),     intent(in)    :: iv     !< index in cg%q array, where we want the particles to be projected
      real,                intent(in)    :: factor !< typically fpiG

      type(cg_list_element), pointer :: cgl
      integer :: p, cdim
      integer(kind=8) :: cn, i, j, k
      integer(kind=8), dimension(ndims, LO:HI) :: ijkp
      integer(kind=8), dimension(ndims) :: cur_ind
      real :: weight

      cgl => leaves%first
      do while (associated(cgl))

         do p = lbound(this%p, dim=1), ubound(this%p, dim=1)
            associate( &
                  field => cgl%cg%q(iv)%arr, &
                  part  => this%p(p), &
                  idl   => cgl%cg%idl &
            )
               if (any(part%pos < cgl%cg%fbnd(:,LO)) .or. any(part%pos > cgl%cg%fbnd(:,HI))) cycle

               do cdim = xdim, zdim
                  if (dom%has_dir(cdim)) then
                     cn = nint((part%pos(cdim) - cgl%cg%coord(CENTER, cdim)%r(1))*cgl%cg%idl(cdim)) + 1
                     if (cgl%cg%coord(CENTER, cdim)%r(cn) > part%pos(cdim)) then
                        ijkp(cdim, LO) = cn - 1
                     else
                        ijkp(cdim, LO) = cn
                     endif
                     ijkp(cdim, HI) = ijkp(cdim, LO) + 1
                  else
                     ijkp(cdim, :) = cgl%cg%ijkse(cdim, :)
                  endif
               enddo
               do i = ijkp(xdim, LO), ijkp(xdim, HI)
                  do j = ijkp(ydim, LO), ijkp(ydim, HI)
                     do k = ijkp(zdim, LO), ijkp(zdim, HI)
                        weight = factor * part%mass / cgl%cg%dvol
                        cur_ind(:) = [i, j, k]
                        do cdim = xdim, zdim
                           if (dom%has_dir(cdim)) &
                              weight = weight*( 1.0 - abs(part%pos(cdim) - cgl%cg%coord(CENTER, cdim)%r(cur_ind(cdim)))*idl(cdim) )
                        enddo
                        field(i,j,k) = field(i,j,k) +  weight
                      enddo
                  enddo
               enddo
            end associate
         enddo
         print *, sum(cgl%cg%q(iv)%arr)
         cgl => cgl%nxt
      enddo

   end subroutine map_cic

   subroutine map_tsc(this, iv, factor)

      use cg_leaves, only: leaves
      use cg_list,   only: cg_list_element
      use constants, only: xdim, ydim, zdim, ndims, LO, HI, IM, I0, IP, CENTER
      use domain,    only: dom

      implicit none

      class(particle_set), intent(in)    :: this   !< an object invoking the type-bound procedure
      integer(kind=4),     intent(in)    :: iv     !< index in cg%q array, where we want the particles to be projected
      real,                intent(in)    :: factor !< typically fpiG

      type(cg_list_element), pointer :: cgl
      integer :: p, cdim
      integer(kind=8) :: i, j, k
      integer(kind=8), dimension(ndims, IM:IP) :: ijkp
      integer(kind=8), dimension(ndims) :: cur_ind
      real :: weight, delta_x, a, weight_tmp

      cgl => leaves%first
      do while (associated(cgl))

         do p = lbound(this%p, dim=1), ubound(this%p, dim=1)
            associate( &
                  field => cgl%cg%q(iv)%arr, &
                  part  => this%p(p), &
                  idl   => cgl%cg%idl &
            )
               if (any(part%pos < cgl%cg%fbnd(:,LO)) .or. any(part%pos > cgl%cg%fbnd(:,HI))) cycle

               do cdim = xdim, zdim
                  if (dom%has_dir(cdim)) then
                     ijkp(cdim, I0) = nint((part%pos(cdim) - cgl%cg%coord(CENTER, cdim)%r(1))*cgl%cg%idl(cdim)) + 1   !!! BEWARE hardcoded magic
                     ijkp(cdim, IM) = max(ijkp(cdim, I0) - 1, int(cgl%cg%lhn(cdim, LO), kind=8))
                     ijkp(cdim, IP) = min(ijkp(cdim, I0) + 1, int(cgl%cg%lhn(cdim, HI), kind=8))
                  else
                     ijkp(cdim, IM) = cgl%cg%ijkse(cdim, LO)
                     ijkp(cdim, I0) = cgl%cg%ijkse(cdim, LO)
                     ijkp(cdim, IP) = cgl%cg%ijkse(cdim, HI)
                  endif
               enddo
               a = 0.0
               do i = ijkp(xdim, IM), ijkp(xdim, IP)
                  do j = ijkp(ydim, IM), ijkp(ydim, IP)
                     do k = ijkp(zdim, IM), ijkp(zdim, IP)

                        cur_ind(:) = [i, j, k]
                        weight = 1.0

                        do cdim = xdim, zdim
                           if (.not.dom%has_dir(cdim)) cycle
                           delta_x = ( part%pos(cdim) - cgl%cg%coord(CENTER, cdim)%r(cur_ind(cdim)) ) * idl(cdim)
                           if (cur_ind(cdim) /= ijkp(cdim, 0)) then   !!! BEWARE hardcoded magic
                              weight_tmp = 1.125 - 1.5 * abs(delta_x) + 0.5 * delta_x**2
                           else
                              weight_tmp = 0.75 - delta_x**2
                           endif
                           weight = weight_tmp * weight
                        enddo

                        field(i, j, k) = field(i, j, k) + factor * (part%mass / cgl%cg%dvol) * weight
                      enddo
                  enddo
               enddo
            end associate
         enddo

         cgl => cgl%nxt
      enddo

   end subroutine map_tsc

   function particle_with_id_exists(this, id) result (tf)

      implicit none

      class(particle_set), intent(inout) :: this
      integer,             intent(in)    :: id

      logical :: tf

      tf = allocated(this%p)
      if (tf) tf = (id >= lbound(this%p, dim=1)) .and. (id <= ubound(this%p, dim=1))

   end function particle_with_id_exists

   subroutine particle_set_evolve(this, func, t, dt)

      implicit none

      class(particle_set),      intent(inout) :: this
      class(particle_solver_T), intent(inout) :: func
      real,                     intent(in)    :: t
      real,                     intent(in)    :: dt

      call func%evolve(this, t, dt)

   end subroutine particle_set_evolve

end module particle_types
