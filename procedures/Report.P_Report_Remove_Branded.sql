--liquibase formatted sql

--changeset Nicolas Griesdorn d5271906 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--      Author : Jacob Lowe
--             :
--     Created : 2018-03-19
--             :
-- Description : Remove Branded for resell
--             :
-- NG20231117  : Added Omar Jassin to approved users to use this report
-- NG20240402  : Added Brad Pillar to approved users to use this report
-- =============================================
ALTER PROCEDURE [Report].[P_Report_Remove_Branded]
    (
        @Sim VARCHAR(40),
        @SessionUserID INT
    )
AS
BEGIN TRY

    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @PAKid INT,
        @Kit VARCHAR(MAX),
        @PAKidKit INT,
        @SISid INT,
        @SISidKit INT;

    IF
        NOT EXISTS
        (
            SELECT 1
            FROM dbo.Users
            WHERE
                User_ID = ISNULL(@SessionUserID, -1)
                AND Account_ID = 2
                AND User_ID IN (145761, 137590, 282225, 281818) --NG20240402
        )
        BEGIN
            SELECT 'This User is not authorized to run this process.' AS [ERROR];
            RETURN;
        END;


    IF (ISNULL(@Sim, '') = '')
        BEGIN
            SELECT 'Missing SIM/ESN' AS [Error Message];
            RETURN;
        END;

    IF (
        (
            SELECT COUNT(1)
            FROM dbo.Phone_Active_Kit AS pak WITH (NOLOCK)
            WHERE pak.Sim_ID = @Sim
            --AND pak.Active_Status IN ( 'branded', 'TCBranded' )
            AND pak.Status = 1
        ) <> 1
    )
        BEGIN
            SELECT 'SIM/ESN not found or found multiple' AS [Error];
            RETURN;
        END;

    SELECT
        @PAKid = pak.ID,
        @PAKidKit = pak2.ID,
        @Kit = pak2.Sim_ID
    FROM dbo.Phone_Active_Kit AS pak WITH (NOLOCK)
    LEFT JOIN dbo.Phone_Active_Kit AS pak2
        ON
            pak2.Kit_Number = pak.Kit_Number
            AND pak2.Status = 1
            AND pak.Kit_Number IS NOT NULL
    WHERE pak.Sim_ID = @Sim
    --AND pak.Active_Status IN ( 'branded', 'TCBranded' )
    AND pak.Status = 1;

    SELECT @SISid = sis.SerializedInventorySoldID
    FROM MarketPlace.tblSerializedInventorySold AS sis
    WHERE sis.SerialNumber = @Sim;

    SELECT @SISidKit = sis.SerializedInventorySoldID
    FROM MarketPlace.tblSerializedInventorySold AS sis
    WHERE sis.SerialNumber = @Kit;

    UPDATE dbo.Phone_Active_Kit
    SET Status = 0, Date_Updated = GETDATE(), User_Updated = @SessionUserID
    WHERE ID IN (@PAKid, @PAKidKit);

    UPDATE MarketPlace.tblSerializedInventorySold
    SET Status = 0
    WHERE SerializedInventorySoldID IN (@SISid, @SISidKit);

    SELECT @Sim + ' has been removed.' AS [Confirmation];

END TRY
BEGIN CATCH
    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
