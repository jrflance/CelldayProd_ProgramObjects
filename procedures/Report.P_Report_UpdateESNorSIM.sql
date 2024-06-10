--liquibase formatted sql

--changeset Nicolas Griesdorn bfa9aa6d stripComments:false runOnChange:true splitStatements:false
/* =============================================
				:
	Author		: Nic Griesdorn
				:
	Created		: 2024-05-09
				:
	Description	: SP used in CRM to update ESNs or SIMs that are incorrect
				:
============================================= */
CREATE OR ALTER PROCEDURE [Report].[P_Report_UpdateESNorSIM]
    (
        @SessionID INT
        , @Option INT
        , @OriginalESNorSIM NVARCHAR(50)
        , @UpdatedESNorSIM NVARCHAR(50)
    )
AS
BEGIN TRY
    IF ISNULL(@OriginalESNorSIM, '') = ''
        RAISERROR ('The Original ESN or SIM column cannot be left blank, please correct the column and try again.', 12, 1);
    -----------------------------------------------------------------------------------------------------------------

    IF @Option = 0 -- View ESN or SIM
        BEGIN
            SELECT
                p.Sim_ID
                , p.Status AS [Device Status]
                , p.Active_Status AS [Activation Status]
                , p.order_no AS [Activation Order No]
                , p.Product_ID
                , po.Name AS [Product Name]
                , p.Assigned_Merchant_ID AS [Assigned Account ID]
                , p.PONumber AS [Device Purchase Order]

            FROM dbo.Phone_Active_Kit AS p
            JOIN dbo.Products AS po ON po.Product_ID = p.Product_ID
            WHERE @OriginalESNorSIM = p.Sim_ID
        END;

    -----------------------------------------------------------------------------------------------------------------

    IF @Option = 1 -- Update ESN or SIM
        BEGIN
            IF NOT EXISTS (SELECT * FROM dbo.Phone_Active_Kit AS p WHERE @OriginalESNorSIM = Sim_ID)
                RAISERROR ('The Original ESN or SIM provided currently does not exist, please verify and try again.', 14, 1);

            IF EXISTS (SELECT * FROM dbo.Phone_Active_Kit AS p WHERE @OriginalESNorSIM = Sim_ID AND Status = 0)
                RAISERROR ('The Original ESN or SIM provided currently is marked an inactive, please verify and try again.', 14, 1);

            IF EXISTS (SELECT p.Active_Status FROM dbo.Phone_Active_Kit AS p WHERE @OriginalESNorSIM = p.Sim_ID AND p.Active_Status = 1)
                RAISERROR ('The Original ESN or SIM provided is currently in an active status, it cannot be moved.', 14, 1);

            IF EXISTS (SELECT p.Sim_ID FROM dbo.Phone_Active_Kit AS p WHERE @UpdatedESNorSIM = p.Sim_ID AND p.Sim_ID <> '')
                RAISERROR ('The Updated ESN or SIM already exists in the system, if you receive this error please reach out to IT Support.', 14, 1);

            IF ISNULL(@UpdatedESNorSIM, '') = ''
                RAISERROR ('The Updated ESN or SIM column cannot be left blank, please correct and try again.', 14, 1);

            UPDATE dbo.Phone_Active_Kit
            SET Sim_ID = @UpdatedESNorSIM
            WHERE Sim_ID = @OriginalESNorSIM

            SELECT
                p.Sim_ID
                , p.Status AS [Device Status]
                , p.Active_Status AS [Activation Status]
                , p.order_no AS [Activation Order No]
                , p.Product_ID
                , po.Name AS [Product Name]
                , p.Assigned_Merchant_ID AS [Assigned Account ID]
                , p.PONumber AS [Device Purchase Order]

            FROM dbo.Phone_Active_Kit AS p
            JOIN dbo.Products AS po ON po.Product_ID = p.Product_ID
            WHERE @OriginalESNorSIM = p.Sim_ID OR @UpdatedESNorSIM = p.Sim_ID
        END;






END TRY
BEGIN CATCH
    SELECT ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
