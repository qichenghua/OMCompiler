/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-CurrentYear, Linköping University,
 * Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3
 * AND THIS OSMC PUBLIC LICENSE (OSMC-PL).
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES RECIPIENT'S
 * ACCEPTANCE OF THE OSMC PUBLIC LICENSE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from Linköping University, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS
 * OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package HpcOmSchedulerExt
" file:        HpcOmSchedulerExt.mo
  package:     HpcOmSchedulerExt
  description: Reads schedule-informations from external files.

  RCS: $Id: HpcOmSchedulerExt.mo 2013-09-27 marcusw $

  "
  
public function readScheduleFromGraphMl
  input String filename;
  output list<Integer> res;
  external "C" res=HpcOmSchedulerExt_readScheduleFromGraphMl(filename) annotation(Library = "omcruntime");
end readScheduleFromGraphMl;

public function scheduleMetis
  input array<Integer> xadj;
  input array<Integer> adjncy;
  input array<Integer> vwgt;
  input array<Integer> adjwgt;
  output list<Integer> res;
  external "C" res=HpcOmSchedulerExt_scheduleMetis(xadj,adjncy,vwgt,adjwgt) annotation(Library = "omcruntime");
end scheduleMetis;

end HpcOmSchedulerExt;