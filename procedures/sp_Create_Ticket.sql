--liquibase formatted sql

--changeset jrose:5B0C57B5-0359-49D9-9E89-72E58F2987B5 stripComments:false runOnChange:true endDelimiter:/
-- =============================================
--             : 
--      Author : 
--             : 
--     Created : 
--             : 
--       Usage : 
--             : 
-- Description : Creates a CRM Ticket
--             : 
--  JR20240201 : Formatting. Corrected @comments parameter to VARCHAR(1500) to match db column.
--             : 
-- =============================================
-- noqa: disable=all
CREATE OR ALTER PROCEDURE [dbo].[sp_Create_Ticket]
-- noqa: enable=all
    (
        @AccountID INT,
        @callType CHAR(10),
        @ticketHeaderID INT,
        @UserID INT,
        @department INT,
        @reason INT,
        @priority INT,
        @status INT,
        @comments VARCHAR(1500), -- JR20240201
        @ticketID INT OUTPUT
    )
AS
BEGIN

    IF (@callType = 'Call')
        BEGIN
            INSERT INTO dbo.CRM_Calllog (Act_ID, Create_UserID, Create_DTM, Comment, Reason, Status)
            VALUES (@AccountID, @UserID, GETDATE(), @comments, @reason, 1)
        END
    ELSE
        BEGIN
            IF (@ticketHeaderID = 0)
                BEGIN
                    INSERT INTO dbo.CRM_Tickethdr (Act_ID, Create_DTM, Create_UserID, Priority, Reason, Status)
                    VALUES (@AccountID, GETDATE(), @UserID, @priority, @reason, @status)
                    SET @ticketID = @@IDENTITY
                END
            ELSE
                BEGIN
                    SET @ticketID = @ticketHeaderID

                    UPDATE dbo.CRM_Tickethdr
                    SET
                        Update_UserID = @UserID,
                        Reason = @reason,
                        Update_DTM = GetDate()

                    WHERE ID = @ticketHeaderID
                END

            INSERT INTO dbo.CRM_TicketDetail (
                Ticket_ID, Create_DTM, Create_UserID, Assign_Dep, Reason, Status,
                Comments, Call_ID
            )
            VALUES (@ticketID, GETDATE(), @UserID, @department, @reason, @status, @comments, 6322)

            IF (@status = 1 OR @status = 2)
                BEGIN
                    UPDATE dbo.CRM_Tickethdr
                    SET Status = @status
                    WHERE ID = @ticketID
                END
        END
END
-- noqa: disable=all
/