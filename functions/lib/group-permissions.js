'use strict';

function isGroupAdmin(groupData, uid, isMember) {
  return !!groupData && (groupData.ownerDeviceId === uid ||
    (groupData.allMembersAreAdmins === true && isMember === true));
}

module.exports = { isGroupAdmin };
