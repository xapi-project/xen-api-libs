/***********************************************************************/
/*                                                                     */
/*                           Objective Caml                            */
/*                                                                     */
/*            Xavier Leroy, projet Cristal, INRIA Rocquencourt         */
/*                                                                     */
/*  Copyright 1996 Institut National de Recherche en Informatique et   */
/*  en Automatique.  All rights reserved.  This file is distributed    */
/*  under the terms of the GNU Library General Public License, with    */
/*  the special exception on linking described in file ../../LICENSE.  */
/*                                                                     */
/***********************************************************************/

/* $Id: read.c 4144 2001-12-07 13:41:02Z xleroy $ */

#include <string.h>
#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/signals.h>
#include <caml/unixsupport.h>

#define BLOCK_SIZE 512

CAMLprim value stub_stdext_unix_read(value fd, value buf, value ofs, value len)
{
  long numbytes;
  int ret;
  void *iobuf = NULL;

  Begin_root (buf);
    numbytes = Long_val(len);
    ret = posix_memalign(&iobuf, BLOCK_SIZE, numbytes);
    if (ret != 0)
      uerror("read/posix_memalign", Nothing);
    enter_blocking_section();
    ret = read(Int_val(fd), iobuf, (int) numbytes);
    leave_blocking_section();
    if (ret == -1) uerror("read", Nothing);
    memmove (&Byte(buf, Long_val(ofs)), iobuf, ret);
    free(iobuf);
  End_roots();
  return Val_int(ret);
}
